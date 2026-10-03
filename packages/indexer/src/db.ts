// One small interface over two drivers: PGlite (Postgres in WASM) for local dev and tests,
// node-postgres for a real server. DATABASE_URL picks: "pglite:" (in memory), "pglite:<dir>", or "postgres://...".
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export type Row = Record<string, any>
export type Queryable = {
  query<T extends Row = Row>(text: string, params?: unknown[]): Promise<{ rows: T[] }>
}
export type Db = Queryable & {
  exec(sql: string): Promise<void>
  transaction<T>(fn: (tx: Queryable) => Promise<T>): Promise<T>
  close(): Promise<void>
}

export async function openDb(url: string): Promise<Db> {
  if (url.startsWith('pglite:')) {
    const { PGlite } = await import('@electric-sql/pglite')
    const dir = url.slice('pglite:'.length)
    const pg = new PGlite(dir || undefined, { parsers: { 20: (v: string) => Number(v) } })
    await pg.waitReady
    return {
      query: (text, params) => pg.query(text, params) as never,
      exec: async (sql) => {
        await pg.exec(sql)
      },
      transaction: (fn) => pg.transaction((tx) => fn({ query: (t, p) => tx.query(t, p) as never })),
      close: () => pg.close(),
    }
  }

  const { default: pgLib } = await import('pg')
  // int8 arrives as a string by default; every int8 here (ids, blocks) fits a JS number.
  pgLib.types.setTypeParser(20, (v: string) => Number(v))
  const pool = new pgLib.Pool({ connectionString: url })
  return {
    query: (text, params) => pool.query(text, params as unknown[]) as never,
    exec: async (sql) => {
      await pool.query(sql)
    },
    transaction: async (fn) => {
      const client = await pool.connect()
      try {
        await client.query('begin')
        const out = await fn({ query: (t, p) => client.query(t, p as unknown[]) as never })
        await client.query('commit')
        return out
      } catch (e) {
        await client.query('rollback')
        throw e
      } finally {
        client.release()
      }
    },
    close: () => pool.end(),
  }
}

const here = dirname(fileURLToPath(import.meta.url))

export async function migrate(db: Db): Promise<void> {
  await db.exec(readFileSync(resolve(here, 'schema.sql'), 'utf8'))
}
