// Canteen parameters (spec V1, V5). Source of truth is config/canteen.json, shared with the deploy script.
// Times are seconds after IST midnight; prices are in paise.
import raw from '../../../config/canteen.json' with { type: 'json' }

export type SlotConfig = { id: number; startSec: number; label: string }
export type ItemConfig = { id: number; name: string; pricePaise: number }

export const canteenConfig: {
  /** V1: Google Workspace domain. The backend accepts only ID tokens whose `hd` claim equals this. */
  collegeEmailDomain: string
  orderWindow: { openSec: number; cutoffSec: number }
  /** Physical portions per slot. The contract caps pre-orders at 30% of this. */
  slotCapacity: number
  slots: SlotConfig[]
  items: ItemConfig[]
} = raw

/** Pre-order portions per slot (30% of physical capacity, same rounding as the contract). */
export const preorderCap = (capacity: number) => Math.floor((capacity * 3000) / 10_000)
