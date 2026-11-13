"""Write-ahead delivery receipts for callers with a durable, serialized state store."""
from datetime import datetime, timezone
import hashlib
from smtp_delivery import definitely_rejected, PartialDeliveryError


class DeliveryUncertain(RuntimeError):
    pass


def deliver_once(state, key, send, save):
    receipts = state.setdefault('delivery_receipts', {})
    previous = receipts.get(key, {})
    if previous.get('status') == 'accepted':
        return False
    if previous.get('status') in ('sending', 'uncertain', 'partial'):
        raise DeliveryUncertain('Delivery requires review before retry: ' + key)
    receipt = {'status': 'sending', 'attempted_at': datetime.now(timezone.utc).isoformat()}
    receipts[key] = receipt
    # If this write is not confirmed, do not contact SMTP at all.
    save()
    try:
        send()
    except Exception as error:
        receipt['status'] = 'rejected' if definitely_rejected(error) else 'uncertain'
        if isinstance(error, PartialDeliveryError):
            opaque = lambda address: hashlib.sha256(address.lower().encode()).hexdigest()
            receipt.update(status='partial', accepted=[opaque(a) for a in error.accepted],
                           rejected=[opaque(a) for a in error.refused])
        save()
        raise
    receipt.update(status='accepted', accepted_at=datetime.now(timezone.utc).isoformat())
    save()
    return True
