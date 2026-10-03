// IST time model (spec section 4). All contract times are seconds since epoch; dayId counts IST days.
export const IST_OFFSET = 19800

export const dayId = (ts: number) => Math.floor((ts + IST_OFFSET) / 86400)
export const dayStart = (d: number) => d * 86400 - IST_OFFSET
export const secondOfDay = (ts: number) => (ts + IST_OFFSET) % 86400

/** Order status as stored on chain (enum CanteenOrders.Status). */
export const OrderStatus = ['None', 'Placed', 'CheckedIn', 'Served', 'Forfeited', 'RefundOwed', 'RefundPaid'] as const
export type OrderStatusName = (typeof OrderStatus)[number]

/** RefundOwed reason (enum CanteenOrders.Reason). */
export const RefundReason = ['None', 'Unserved', 'ItemUnavailable'] as const
