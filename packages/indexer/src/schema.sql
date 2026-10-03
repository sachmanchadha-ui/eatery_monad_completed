-- CanteenPOS Postgres schema (spec 6.2). Idempotent: safe to run on every start.
-- Chain-derived tables are a cache of contract state; `rebuild` truncates and replays them.
-- Off-chain tables (students, intents, payments, jobs, audit_log) are never truncated.

-- ---------- indexer bookkeeping ----------
create table if not exists chain_cursor (
  id                   smallint primary key default 1 check (id = 1),
  chain_id             integer  not null,
  contract             text     not null,
  deploy_block         bigint   not null,
  last_processed_block bigint   not null,
  updated_at           timestamptz not null default now()
);

create table if not exists chain_events (
  tx_hash      text    not null,
  log_index    integer not null,
  block_number bigint  not null,
  block_time   timestamptz not null,
  event        text    not null,
  args         jsonb   not null,
  primary key (tx_hash, log_index)
);
create index if not exists chain_events_position on chain_events (block_number, log_index);

-- ---------- off-chain (written by the backend in P3) ----------
create table if not exists students (
  wallet_address  text primary key,
  privy_user_id   text unique,
  email_domain_ok boolean not null default false,
  created_at      timestamptz not null default now()
);

create table if not exists intents (
  intent_hash       text primary key,
  student           text not null,
  slot_id           smallint not null,
  lines_json        jsonb not null,
  total_paise       integer not null,
  razorpay_order_id text,
  status            text not null default 'reserved',
  reserved_until    timestamptz,
  created_at        timestamptz not null default now()
);

create table if not exists payments (
  payment_ref         text primary key,
  intent_hash         text not null references intents (intent_hash),
  provider_payment_id text,
  amount_paise        integer not null,
  captured_at         timestamptz not null default now()
);

create table if not exists jobs (
  id         bigserial primary key,
  kind       text not null,
  payload    jsonb not null default '{}',
  run_at     timestamptz not null default now(),
  attempts   integer not null default 0,
  last_error text,
  done_at    timestamptz
);
create index if not exists jobs_due on jobs (run_at) where done_at is null;

create table if not exists audit_log (
  id      bigserial primary key,
  actor   text not null,
  action  text not null,
  tx_hash text,
  detail  jsonb,
  at      timestamptz not null default now()
);

-- ---------- chain-derived ----------
create table if not exists session_keys (
  student          text primary key,
  key_address      text not null,
  expiry           timestamptz not null,
  registered_tx    text not null,
  registered_block bigint not null
);

create table if not exists orders (
  order_id        bigint primary key,
  student         text not null,
  day_id          integer not null,
  slot_id         smallint not null,
  token_no        integer not null,
  payment_ref     text not null unique,
  intent_hash     text,
  total_paise     integer not null,
  status          text not null,
  refund_reason   text,
  placed_at       timestamptz not null,
  present_at      timestamptz,
  checkin_device  text,
  served_by       text,
  placed_tx       text not null,
  last_event_block bigint not null,
  last_event_log   integer not null,
  updated_at      timestamptz not null default now()
);
create index if not exists orders_day_slot on orders (day_id, slot_id, status);
create index if not exists orders_student on orders (student);

create table if not exists order_lines (
  order_id         bigint not null references orders (order_id) on delete cascade,
  line_no          smallint not null,
  item_id          integer not null,
  qty              integer not null,
  unit_price_paise integer not null,
  primary key (order_id, line_no)
);

create table if not exists refunds (
  order_id           bigint primary key references orders (order_id) on delete cascade,
  reason             text not null,
  amount_paise       integer not null,
  status             text not null,          -- owed | paid
  razorpay_refund_id text,                   -- set by the refund executor (P3/P8)
  refund_ref         text,                   -- as recorded on chain by recordRefundPaid
  owed_tx            text not null,
  owed_at            timestamptz not null,
  recorded_tx        text,
  paid_at            timestamptz
);
create index if not exists refunds_open on refunds (owed_at) where status = 'owed';

create table if not exists devices (
  address          text primary key,
  authorized_at    timestamptz,
  authorized_tx    text,
  revoked_at       timestamptz,
  revoked_tx       text
);

create table if not exists item_availability (
  day_id       integer not null,
  item_id      integer not null,
  available    boolean not null,
  changed_at   timestamptz not null,
  tx_hash      text not null,
  primary key (day_id, item_id)
);
