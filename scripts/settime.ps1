# Send the current time (Nairobi, UTC+3) to a Trezor Model One running this firmware.
$u = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
trezorctl ping "SETTIME $u 10800"
