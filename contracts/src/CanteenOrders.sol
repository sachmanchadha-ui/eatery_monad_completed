// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title CanteenOrders
/// @notice Fund-free pre-order state machine for a campus canteen (CanteenPOS spec v2, section 5).
///         The contract holds no money. It is the public rulebook and ledger: paid orders,
///         student-signed check-ins, service records, forfeits and refund obligations.
/// @dev All times are IST (UTC+05:30). dayId = (timestamp + 19800) / 86400.
contract CanteenOrders is EIP712 {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum Status {
        None,
        Placed,
        CheckedIn,
        Served,
        Forfeited,
        RefundOwed,
        RefundPaid
    }
    enum Reason {
        None,
        Unserved,
        ItemUnavailable
    }
    enum ConfigKind {
        None,
        Slot,
        Item
    }
    enum Role {
        None,
        Attester,
        Refunder,
        Relayer
    }

    struct Line {
        uint16 itemId;
        uint16 qty;
        uint32 unitPricePaise;
    }

    struct OrderIntent {
        address student;
        uint8 slotId;
        bytes32 linesHash;
        uint32 totalPaise;
        uint256 nonce;
        uint48 deadline;
    }

    struct DeviceChallenge {
        address device;
        uint8 slotId;
        bytes32 nonce;
        uint48 timestamp;
    }

    struct SessionKey {
        address key;
        uint48 expiry;
    }

    struct Order {
        address student;
        uint32 dayId;
        uint8 slotId;
        uint32 tokenNo;
        Status status;
        Reason reason;
        uint48 placedAt;
        uint48 claimStart; // snapshot at placement, so later schedule edits never move an order's window
        uint48 presentAt;
        uint32 totalPaise;
        bytes32 paymentRef;
    }

    struct SlotConfig {
        uint32 startSec;
        uint16 capacity;
        bool active;
    }

    struct ItemConfig {
        uint32 pricePaise;
        bool active;
    }

    struct SlotSchedule {
        SlotConfig current;
        SlotConfig next;
        uint32 nextDay;
        bool exists;
    }

    struct ItemSchedule {
        ItemConfig current;
        ItemConfig next;
        uint32 nextDay;
        bool exists;
    }

    struct DeviceInfo {
        uint48 authorizedAt;
        uint48 revokedAt;
    }

    // ------------------------------------------------------------------
    // Parameters (spec section 4)
    // ------------------------------------------------------------------

    uint256 internal constant IST = 19800;
    uint256 public immutable OPEN_SEC;
    uint256 public immutable CUTOFF_SEC;
    uint256 public constant CLAIM_WINDOW = 30 minutes;
    uint256 public constant SUBMIT_GRACE = 30 minutes;
    uint256 public constant SERVE_GRACE = 20 minutes;
    uint256 public constant SESSION_TTL = 30 days;
    uint256 public constant PREORDER_CAP_BPS = 3000;
    uint256 public constant MAX_LINES = 4;
    uint256 public constant MAX_QTY_PER_LINE = 10;
    uint256 public constant MAX_USES_PER_CHALLENGE = 8;
    /// @notice Tolerance for a tablet clock running ahead of block time.
    uint256 public constant CLOCK_SKEW = 30 seconds;

    bytes32 public constant INTENT_TYPEHASH = keccak256(
        "OrderIntent(address student,uint8 slotId,bytes32 linesHash,uint32 totalPaise,uint256 nonce,uint48 deadline)"
    );
    bytes32 public constant PAYMENT_TYPEHASH = keccak256("PaymentAttestation(bytes32 intentHash,bytes32 paymentRef)");
    bytes32 public constant CHALLENGE_TYPEHASH =
        keccak256("DeviceChallenge(address device,uint8 slotId,bytes32 nonce,uint48 timestamp)");
    bytes32 public constant CHECKIN_TYPEHASH = keccak256("CheckIn(uint256 orderId,bytes32 challengeHash)");
    bytes32 public constant SESSION_TYPEHASH =
        keccak256("SessionKeyAuth(address student,address key,uint48 expiry,uint256 nonce)");

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------

    address public owner;
    address public pendingOwner;
    address public attester;
    address public refunder;
    address public relayer;

    mapping(address => DeviceInfo) public devices;
    mapping(address => SessionKey) public sessionKeys;
    mapping(address => uint256) public sessionNonce;

    mapping(uint8 => SlotSchedule) internal _slots;
    mapping(uint16 => ItemSchedule) internal _items;
    uint8[] internal _slotIds;
    uint16[] internal _itemIds;

    uint256 public orderCount;
    mapping(uint256 => Order) internal _orders;
    mapping(uint256 => Line[]) internal _orderLines;
    mapping(address => mapping(uint256 => bool)) public intentNonceUsed;
    mapping(bytes32 => bool) public paymentRefUsed;

    mapping(uint256 => mapping(uint8 => uint256)) public slotUsed; // day => slot => portions
    mapping(uint256 => mapping(uint8 => uint32)) public tokenCounter; // day => slot => last token
    mapping(uint256 => mapping(uint8 => mapping(uint16 => uint256))) public demand; // day => slot => item => qty
    mapping(uint256 => mapping(uint16 => bool)) public offToday; // day => item => currently off
    mapping(uint256 => mapping(uint16 => uint48[])) internal _offTimes; // day => item => switch-off times, ascending
    mapping(bytes32 => uint8) public challengeUses;

    // ------------------------------------------------------------------
    // Events (spec section 5.4)
    // ------------------------------------------------------------------

    event SessionKeyRegistered(address indexed student, address key, uint48 expiry);
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed student,
        uint256 dayId,
        uint8 slotId,
        uint32 tokenNo,
        bytes32 paymentRef,
        uint32 totalPaise
    );
    event CheckedIn(uint256 indexed orderId, address indexed device, uint48 presentAt);
    event Served(uint256 indexed orderId, address indexed device);
    event Forfeited(uint256 indexed orderId);
    event RefundOwed(uint256 indexed orderId, uint8 reason);
    event RefundPaid(uint256 indexed orderId, bytes32 refundRef);
    event ItemAvailability(uint256 indexed dayId, uint16 indexed itemId, bool available);
    event DeviceAuthorized(address indexed device);
    event DeviceRevoked(address indexed device);
    event ConfigScheduled(uint8 indexed kind, uint256 indexed id, uint256 effectiveDay);
    event RoleUpdated(uint8 indexed role, address account);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error OutsideWindow();
    error IntentExpired();
    error NonceUsed();
    error NoSessionKey();
    error BadStudentSig();
    error BadAttestation();
    error PaymentReused();
    error BadLines();
    error LinesMismatch();
    error BadLine();
    error BadSlot();
    error SlotFull();
    error BadTotal();
    error BadStatus();
    error TooLate();
    error WrongSlot();
    error ChallengeOutOfWindow();
    error DeviceNotAuthorized();
    error BadDeviceSig();
    error ChallengeExhausted();
    error NotDevice();
    error NotYet();
    error NotAllowed();
    error Refundable();
    error BadConfig();
    error ZeroAddress();

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    constructor(uint256 openSec, uint256 cutoffSec, address attester_, address refunder_, address relayer_)
        EIP712("CanteenOrders", "1")
    {
        if (openSec >= cutoffSec || cutoffSec > 1 days) revert BadConfig();
        if (attester_ == address(0) || refunder_ == address(0) || relayer_ == address(0)) revert ZeroAddress();
        OPEN_SEC = openSec;
        CUTOFF_SEC = cutoffSec;
        owner = msg.sender;
        attester = attester_;
        refunder = refunder_;
        relayer = relayer_;
        emit OwnershipTransferred(address(0), msg.sender);
        emit RoleUpdated(uint8(Role.Attester), attester_);
        emit RoleUpdated(uint8(Role.Refunder), refunder_);
        emit RoleUpdated(uint8(Role.Relayer), relayer_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAllowed();
        _;
    }

    // ------------------------------------------------------------------
    // Session keys
    // ------------------------------------------------------------------

    /// @notice Registers `key` as the student's session key. Anyone may relay the student wallet's signature.
    /// @dev The per-student nonce stops an old authorization from being replayed to restore a replaced key.
    function registerSessionKey(address student, address key, uint48 expiry, uint256 nonce, bytes calldata sig)
        external
    {
        if (key == address(0)) revert ZeroAddress();
        if (expiry <= block.timestamp || expiry > block.timestamp + SESSION_TTL) revert NotAllowed();
        if (nonce != sessionNonce[student]) revert NonceUsed();
        bytes32 h = _hashTypedDataV4(keccak256(abi.encode(SESSION_TYPEHASH, student, key, expiry, nonce)));
        if (ECDSA.recover(h, sig) != student) revert BadStudentSig();
        sessionNonce[student] = nonce + 1;
        sessionKeys[student] = SessionKey(key, expiry);
        emit SessionKeyRegistered(student, key, expiry);
    }

    // ------------------------------------------------------------------
    // Place
    // ------------------------------------------------------------------

    function placeOrder(
        OrderIntent calldata i,
        Line[] calldata lines,
        bytes calldata studentSig,
        bytes32 paymentRef,
        bytes calldata attesterSig
    ) external returns (uint256 orderId) {
        uint256 sod = (block.timestamp + IST) % 1 days;
        if (sod < OPEN_SEC || sod >= CUTOFF_SEC) revert OutsideWindow();
        if (block.timestamp > i.deadline) revert IntentExpired();
        if (intentNonceUsed[i.student][i.nonce]) revert NonceUsed();
        if (paymentRefUsed[paymentRef]) revert PaymentReused();

        _verifyOrderSigs(i, studentSig, paymentRef, attesterSig);

        if (lines.length == 0 || lines.length > MAX_LINES) revert BadLines();
        if (keccak256(abi.encode(lines)) != i.linesHash) revert LinesMismatch();

        uint256 d = _dayId(block.timestamp);
        SlotConfig memory slot = _slot(d, i.slotId);
        if (!slot.active || slot.startSec <= CUTOFF_SEC) revert BadSlot();

        orderId = ++orderCount;
        {
            (uint256 total, uint256 portions) = _recordLines(orderId, d, i.slotId, lines);
            if (total != i.totalPaise) revert BadTotal();
            uint256 used = slotUsed[d][i.slotId] + portions;
            if (used > (uint256(slot.capacity) * PREORDER_CAP_BPS) / 10_000) revert SlotFull();
            slotUsed[d][i.slotId] = used;
        }

        intentNonceUsed[i.student][i.nonce] = true;
        paymentRefUsed[paymentRef] = true;
        _writeOrder(orderId, i, d, _dayStart(d) + slot.startSec, paymentRef);
    }

    function _writeOrder(uint256 orderId, OrderIntent calldata i, uint256 d, uint256 claimStart, bytes32 paymentRef)
        internal
    {
        uint32 tokenNo = ++tokenCounter[d][i.slotId];
        Order storage o = _orders[orderId];
        o.student = i.student;
        o.dayId = uint32(d);
        o.slotId = i.slotId;
        o.tokenNo = tokenNo;
        o.status = Status.Placed;
        o.placedAt = uint48(block.timestamp);
        o.claimStart = uint48(claimStart);
        o.totalPaise = i.totalPaise;
        o.paymentRef = paymentRef;
        emit OrderPlaced(orderId, i.student, d, i.slotId, tokenNo, paymentRef, i.totalPaise);
    }

    function _verifyOrderSigs(
        OrderIntent calldata i,
        bytes calldata studentSig,
        bytes32 paymentRef,
        bytes calldata attesterSig
    ) internal view {
        bytes32 intentHash = intentStructHash(i);
        SessionKey memory sk = sessionKeys[i.student];
        if (sk.key == address(0) || block.timestamp > sk.expiry) revert NoSessionKey();
        if (ECDSA.recover(_hashTypedDataV4(intentHash), studentSig) != sk.key) revert BadStudentSig();
        bytes32 payHash = keccak256(abi.encode(PAYMENT_TYPEHASH, intentHash, paymentRef));
        if (ECDSA.recover(_hashTypedDataV4(payHash), attesterSig) != attester) revert BadAttestation();
    }

    function _recordLines(uint256 orderId, uint256 d, uint8 slotId, Line[] calldata lines)
        internal
        returns (uint256 total, uint256 portions)
    {
        Line[] storage stored = _orderLines[orderId];
        for (uint256 k; k < lines.length; ++k) {
            Line calldata l = lines[k];
            ItemConfig memory item = _item(d, l.itemId);
            if (
                !item.active || offToday[d][l.itemId] || item.pricePaise != l.unitPricePaise || l.qty == 0
                    || l.qty > MAX_QTY_PER_LINE
            ) revert BadLine();
            total += uint256(l.unitPricePaise) * l.qty;
            portions += l.qty;
            demand[d][slotId][l.itemId] += l.qty;
            stored.push(l);
        }
    }

    // ------------------------------------------------------------------
    // Check in
    // ------------------------------------------------------------------

    function checkIn(uint256 orderId, DeviceChallenge calldata c, bytes calldata deviceSig, bytes calldata studentSig)
        external
    {
        Order storage o = _orders[orderId];
        if (o.status != Status.Placed) revert BadStatus();
        uint256 cStart = o.claimStart;
        uint256 cEnd = cStart + CLAIM_WINDOW;
        if (block.timestamp > cEnd + SUBMIT_GRACE) revert TooLate();
        if (c.slotId != o.slotId) revert WrongSlot();
        if (c.timestamp < cStart || c.timestamp > cEnd || c.timestamp > block.timestamp + CLOCK_SKEW) {
            revert ChallengeOutOfWindow();
        }
        if (!deviceValidAt(c.device, c.timestamp)) revert DeviceNotAuthorized();

        bytes32 cHash = challengeStructHash(c);
        if (ECDSA.recover(_hashTypedDataV4(cHash), deviceSig) != c.device) revert BadDeviceSig();
        if (challengeUses[cHash] >= MAX_USES_PER_CHALLENGE) revert ChallengeExhausted();

        address key = sessionKeys[o.student].key;
        bytes32 ciHash = keccak256(abi.encode(CHECKIN_TYPEHASH, orderId, cHash));
        if (key == address(0) || ECDSA.recover(_hashTypedDataV4(ciHash), studentSig) != key) revert BadStudentSig();

        challengeUses[cHash]++;
        o.presentAt = c.timestamp;
        o.status = Status.CheckedIn;
        emit CheckedIn(orderId, c.device, c.timestamp);
    }

    // ------------------------------------------------------------------
    // Settle
    // ------------------------------------------------------------------

    function markServed(uint256 orderId) external {
        DeviceInfo memory dv = devices[msg.sender];
        if (dv.authorizedAt == 0 || dv.revokedAt != 0) revert NotDevice();
        Order storage o = _orders[orderId];
        if (o.status != Status.CheckedIn) revert BadStatus();
        o.status = Status.Served;
        emit Served(orderId, msg.sender);
    }

    function flagUnserved(uint256 orderId) external {
        Order storage o = _orders[orderId];
        if (o.status != Status.CheckedIn) revert BadStatus();
        if (block.timestamp <= uint256(o.presentAt) + SERVE_GRACE) revert NotYet();
        o.status = Status.RefundOwed;
        o.reason = Reason.Unserved;
        emit RefundOwed(orderId, uint8(Reason.Unserved));
    }

    function markForfeit(uint256 orderId) external {
        Order storage o = _orders[orderId];
        if (o.status != Status.Placed) revert BadStatus();
        if (block.timestamp <= uint256(o.claimStart) + CLAIM_WINDOW + SUBMIT_GRACE) revert NotYet();
        if (_unavailableRefundable(orderId)) revert Refundable();
        o.status = Status.Forfeited;
        emit Forfeited(orderId);
    }

    function claimUnavailableRefund(uint256 orderId) external {
        Order storage o = _orders[orderId];
        if (o.status != Status.Placed && o.status != Status.CheckedIn) revert BadStatus();
        if (!_unavailableRefundable(orderId)) revert NotAllowed();
        o.status = Status.RefundOwed;
        o.reason = Reason.ItemUnavailable;
        emit RefundOwed(orderId, uint8(Reason.ItemUnavailable));
    }

    function recordRefundPaid(uint256 orderId, bytes32 refundRef) external {
        if (msg.sender != refunder) revert NotAllowed();
        Order storage o = _orders[orderId];
        if (o.status != Status.RefundOwed) revert BadStatus();
        o.status = Status.RefundPaid;
        emit RefundPaid(orderId, refundRef);
    }

    // ------------------------------------------------------------------
    // Availability and devices
    // ------------------------------------------------------------------

    /// @notice Toggles an item for today. Every switch-off is recorded. An order containing the item is
    ///         refundable if a switch-off falls between its placement and its forfeit point
    ///         (claim end + submit grace). Later switch-offs do not affect it.
    function setItemAvailable(uint16 itemId, bool available) external {
        if (msg.sender != relayer && msg.sender != owner) revert NotAllowed();
        uint256 d = _dayId(block.timestamp);
        if (!available && !offToday[d][itemId]) _offTimes[d][itemId].push(uint48(block.timestamp));
        offToday[d][itemId] = !available;
        emit ItemAvailability(d, itemId, available);
    }

    function authorizeDevice(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        if (devices[a].authorizedAt != 0) revert NotAllowed(); // no reuse after revoke
        devices[a].authorizedAt = uint48(block.timestamp);
        emit DeviceAuthorized(a);
    }

    function revokeDevice(address a) external onlyOwner {
        DeviceInfo storage dv = devices[a];
        // A second revoke would push revokedAt later and widen the device's valid period.
        if (dv.authorizedAt == 0 || dv.revokedAt != 0) revert NotAllowed();
        dv.revokedAt = uint48(block.timestamp);
        emit DeviceRevoked(a);
    }

    function deviceValidAt(address a, uint256 ts) public view returns (bool) {
        DeviceInfo memory dv = devices[a];
        return dv.authorizedAt != 0 && ts >= dv.authorizedAt && (dv.revokedAt == 0 || ts < dv.revokedAt);
    }

    // ------------------------------------------------------------------
    // Configuration (owner). Changes to an existing slot or item take effect on the next dayId.
    // The first configuration of a new id takes effect today: no order can reference it yet.
    // ------------------------------------------------------------------

    function setSlot(uint8 slotId, uint32 startSec, uint16 capacity, bool active) external onlyOwner {
        if (startSec <= CUTOFF_SEC || uint256(startSec) + CLAIM_WINDOW > 1 days) revert BadConfig();
        SlotConfig memory cfg = SlotConfig(startSec, capacity, active);
        SlotSchedule storage s = _slots[slotId];
        uint256 today_ = _dayId(block.timestamp);
        uint256 eff;
        if (!s.exists) {
            s.exists = true;
            s.current = cfg;
            _slotIds.push(slotId);
            eff = today_;
        } else {
            if (s.nextDay != 0 && today_ >= s.nextDay) s.current = s.next;
            s.next = cfg;
            s.nextDay = uint32(today_ + 1);
            eff = today_ + 1;
        }
        emit ConfigScheduled(uint8(ConfigKind.Slot), slotId, eff);
    }

    function setItem(uint16 itemId, uint32 pricePaise, bool active) external onlyOwner {
        if (active && pricePaise == 0) revert BadConfig();
        ItemConfig memory cfg = ItemConfig(pricePaise, active);
        ItemSchedule storage s = _items[itemId];
        uint256 today_ = _dayId(block.timestamp);
        uint256 eff;
        if (!s.exists) {
            s.exists = true;
            s.current = cfg;
            _itemIds.push(itemId);
            eff = today_;
        } else {
            if (s.nextDay != 0 && today_ >= s.nextDay) s.current = s.next;
            s.next = cfg;
            s.nextDay = uint32(today_ + 1);
            eff = today_ + 1;
        }
        emit ConfigScheduled(uint8(ConfigKind.Item), itemId, eff);
    }

    function setAttester(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        attester = a;
        emit RoleUpdated(uint8(Role.Attester), a);
    }

    function setRefunder(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        refunder = a;
        emit RoleUpdated(uint8(Role.Refunder), a);
    }

    function setRelayer(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        relayer = a;
        emit RoleUpdated(uint8(Role.Relayer), a);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotAllowed();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    function getOrderLines(uint256 orderId) external view returns (Line[] memory) {
        return _orderLines[orderId];
    }

    function getSlotDemand(uint256 dayId, uint8 slotId, uint16 itemId) external view returns (uint256) {
        return demand[dayId][slotId][itemId];
    }

    /// @notice Slot config effective on `dayId`. Exact for today and later; past days are not retained.
    function getSlot(uint256 dayId, uint8 slotId) external view returns (SlotConfig memory) {
        return _slot(dayId, slotId);
    }

    /// @notice Item config effective on `dayId`. Exact for today and later; past days are not retained.
    function getItem(uint256 dayId, uint16 itemId) external view returns (ItemConfig memory) {
        return _item(dayId, itemId);
    }

    function getSlotIds() external view returns (uint8[] memory) {
        return _slotIds;
    }

    function getItemIds() external view returns (uint16[] memory) {
        return _itemIds;
    }

    /// @notice Pre-order portions still available in a slot on `dayId`.
    function slotRemaining(uint256 dayId, uint8 slotId) external view returns (uint256) {
        SlotConfig memory s = _slot(dayId, slotId);
        if (!s.active) return 0;
        uint256 cap = (uint256(s.capacity) * PREORDER_CAP_BPS) / 10_000;
        uint256 used = slotUsed[dayId][slotId];
        return used >= cap ? 0 : cap - used;
    }

    function isItemAvailable(uint256 dayId, uint16 itemId) external view returns (bool) {
        return _item(dayId, itemId).active && !offToday[dayId][itemId];
    }

    function getOffTimes(uint256 dayId, uint16 itemId) external view returns (uint48[] memory) {
        return _offTimes[dayId][itemId];
    }

    function isRefundableForUnavailability(uint256 orderId) external view returns (bool) {
        return _unavailableRefundable(orderId);
    }

    function currentDayId() external view returns (uint256) {
        return _dayId(block.timestamp);
    }

    function claimWindow(uint256 orderId) external view returns (uint256 start, uint256 end) {
        start = _orders[orderId].claimStart;
        end = start + CLAIM_WINDOW;
    }

    // ---------- EIP-712 helpers for clients and parity tests ----------

    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function hashLines(Line[] calldata lines) external pure returns (bytes32) {
        return keccak256(abi.encode(lines));
    }

    function intentStructHash(OrderIntent calldata i) public pure returns (bytes32) {
        return
            keccak256(abi.encode(INTENT_TYPEHASH, i.student, i.slotId, i.linesHash, i.totalPaise, i.nonce, i.deadline));
    }

    function challengeStructHash(DeviceChallenge calldata c) public pure returns (bytes32) {
        return keccak256(abi.encode(CHALLENGE_TYPEHASH, c.device, c.slotId, c.nonce, c.timestamp));
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _dayId(uint256 ts) internal pure returns (uint256) {
        return (ts + IST) / 1 days;
    }

    function _dayStart(uint256 d) internal pure returns (uint256) {
        return d * 1 days - IST;
    }

    function _slot(uint256 d, uint8 id) internal view returns (SlotConfig memory) {
        SlotSchedule storage s = _slots[id];
        if (s.nextDay != 0 && d >= s.nextDay) return s.next;
        return s.current;
    }

    function _item(uint256 d, uint16 id) internal view returns (ItemConfig memory) {
        ItemSchedule storage s = _items[id];
        if (s.nextDay != 0 && d >= s.nextDay) return s.next;
        return s.current;
    }

    function _unavailableRefundable(uint256 id) internal view returns (bool) {
        Order storage o = _orders[id];
        Line[] storage ls = _orderLines[id];
        uint256 from = o.placedAt;
        uint256 to = uint256(o.claimStart) + CLAIM_WINDOW + SUBMIT_GRACE;
        for (uint256 k; k < ls.length; ++k) {
            if (_offBetween(_offTimes[o.dayId][ls[k].itemId], from, to)) return true;
        }
        return false;
    }

    /// @dev True if the ascending list `ts` holds a value in [from, to]. Binary search, so a long
    ///      toggle history cannot make settlement unaffordable.
    function _offBetween(uint48[] storage ts, uint256 from, uint256 to) internal view returns (bool) {
        uint256 lo;
        uint256 hi = ts.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (ts[mid] < from) lo = mid + 1;
            else hi = mid;
        }
        return lo < ts.length && ts[lo] <= to;
    }
}
