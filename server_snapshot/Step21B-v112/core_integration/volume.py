from decimal import Decimal, ROUND_DOWN

def lots_to_protocol_volume(lots:float, *, lot_size_cents:int, min_volume:int, step_volume:int, max_volume:int|None=None)->int:
    """Convert canonical lots to cTrader protocol volume without rounding risk upward.

    cTrader symbol lotSize/minVolume/stepVolume/maxVolume are protocol volumes in cents of units.
    The result is floored to broker step. If it falls below min volume, reject instead of forcing min volume.
    """
    if lots<=0 or lot_size_cents<=0 or min_volume<=0 or step_volume<=0: raise ValueError('INVALID_VOLUME_INPUT')
    raw=Decimal(str(lots))*Decimal(int(lot_size_cents))
    stepped=(raw/Decimal(step_volume)).to_integral_value(rounding=ROUND_DOWN)*Decimal(step_volume)
    v=int(stepped)
    if v<min_volume: raise ValueError('MIN_VOLUME_EXCEEDS_RISK_BUDGET')
    if max_volume and v>max_volume: v=(int(max_volume)//step_volume)*step_volume
    if v<=0: raise ValueError('ZERO_PROTOCOL_VOLUME')
    return v
