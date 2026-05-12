# Convenience constructors and conversions for well-known types.
#
# Loaded after `gen/google/google.jl` so the WKT structs are in scope.
# Each entry adds a method on a generated WKT type; the auto-positional
# `(field..., #unknown_fields)` ctor stays untouched.

import Dates

# Pull `Timestamp` into ProtocGen so we can define methods on it
# directly (`function Timestamp(...)`). `import` (not `using`) is
# required to *extend* a binding from another module on Julia 1.12+.
import .google.protobuf: Timestamp

# Spec range from `json_wkt.jl` — re-checked here so the constructors
# reject the same out-of-range inputs the JSON encoder would.
const _TS_MIN_SECONDS = Int64(-62135596800)   # 0001-01-01T00:00:00Z
const _TS_MAX_SECONDS = Int64(253402300799)   # 9999-12-31T23:59:59Z

function _check_timestamp_seconds(s::Int64)
    if s < _TS_MIN_SECONDS || s > _TS_MAX_SECONDS
        throw(
            ArgumentError(
                "Timestamp seconds out of range [$(Int(_TS_MIN_SECONDS)), $(Int(_TS_MAX_SECONDS))]: $(s)",
            ),
        )
    end
    return nothing
end

"""
    google.protobuf.Timestamp(dt::Dates.DateTime) -> Timestamp

Interpret `dt` as UTC and convert to a `Timestamp`. `DateTime` carries
millisecond precision, so `nanos` will always be a multiple of
1_000_000 and the conversion is lossless in that direction.

Throws `ArgumentError` if `dt` falls outside the protobuf-defined valid
range (`0001-01-01T00:00:00Z` … `9999-12-31T23:59:59.999Z`).
"""
function Timestamp(dt::Dates.DateTime)
    ms = Dates.value(dt - Dates.DateTime(1970, 1, 1))
    seconds, ms_rem = divrem(ms, 1000)
    if ms_rem < 0
        # Spec mandates 0 <= nanos < 1e9 even when seconds is negative.
        seconds -= 1
        ms_rem += 1000
    end
    s64 = Int64(seconds)
    _check_timestamp_seconds(s64)
    return Timestamp(s64, Int32(ms_rem * 1_000_000), UInt8[])
end

"""
    google.protobuf.Timestamp(unix_seconds::Real) -> Timestamp

Convert a unix timestamp (seconds since 1970-01-01 UTC, possibly
fractional) into a `Timestamp`. `Float64` provides roughly microsecond
precision at present-day epochs; pass an integer to avoid float
rounding and to round-trip the full 64-bit second range.

For sub-microsecond precision use the `(seconds, nanos)` form of the
generated constructor directly.
"""
function Timestamp(unix_seconds::Real)
    s = floor(Int64, unix_seconds)
    nanos = Int32(round((unix_seconds - s) * 1_000_000_000))
    if nanos == Int32(1_000_000_000)
        s += 1
        nanos = Int32(0)
    end
    _check_timestamp_seconds(s)
    return Timestamp(s, nanos, UInt8[])
end

"""
    Dates.DateTime(ts::google.protobuf.Timestamp) -> DateTime

Convert a `Timestamp` to a Julia `DateTime` (UTC). `DateTime` only
carries millisecond precision, so sub-millisecond `nanos` are
truncated — round-tripping a Timestamp with sub-ms precision through
`DateTime` is lossy.
"""
function Dates.DateTime(ts::Timestamp)
    ms = ts.seconds * 1000 + div(ts.nanos, 1_000_000)
    return Dates.DateTime(1970, 1, 1) + Dates.Millisecond(ms)
end
