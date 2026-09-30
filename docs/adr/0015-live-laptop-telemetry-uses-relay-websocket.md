# Live laptop telemetry uses the relay WebSocket

> Status: accepted

Vidyut collects laptop telemetry in the laptop Relay and sends it to the
paired Android Device through the existing authenticated WebSocket connection.
The first telemetry set is battery percentage and charging state, memory
usage, storage usage, CPU usage, and CPU temperature. The Relay samples these
values every five seconds. Android treats a value as live for ten seconds;
after that, the Home telemetry surface presents it as unavailable and explains
that the laptop is disconnected or the metric is unavailable.

CPU temperature is read from Linux's hardware-monitor interface, preferring
`k10temp`, `coretemp`, `zenpower`, and `acpitz` in that order, using each
sensor's `temp1_input` value. The hwmon number is not stable, so sensors are
identified by their `name`. A legacy `coretemp.0` path is retained for older
systems. If no usable hwmon value exists, the Relay may use a thermal zone whose
`type` identifies a CPU package/thermal sensor; unrelated zones such as `acpitz`
are not treated as CPU temperature. Warning and critical thresholds mirror
Waybar at 70°C and 82°C. If no CPU sensor is available, the temperature card is
explicitly unavailable.

Home presents five telemetry metrics beneath the single `Send files` action, in
two rows ordered by how much each metric has to say. Memory and storage each
carry a value, a detail line and a progress bar, so they lead as a two-across
row with the wider tiles. Battery, CPU temperature and CPU usage each carry a
single number, so they share a three-across row beneath. Every row is held to
one height, so a tile with a progress bar lines up with its neighbour instead of
floating centre-aligned against a shorter one. The arrangement reads as
symmetric because the busier metrics get the roomier row and the number-only
metrics are grouped together.

This supersedes two earlier arrangements in this ADR. The first specified CPU
usage as a full-width third-row card; that layout was never actually built. The
second put CPU temperature and battery on the first row with CPU usage, memory
and storage together on the second, on the reasoning that a lone full-width card
reads as a separate concern rather than one of five. That reasoning was wrong
about which metrics deserved the room: it left CPU usage sharing a tile width
with memory and storage, which wrap their values and carry progress bars, so
CPU usage rendered short and centre-aligned against two much taller tiles. Commit
b6d9ada had earlier orphaned battery on its own row at compact widths, which is
what the second arrangement was correcting. CPU usage is color-coded as Low
below 50%, Moderate from 50% through 80%, and High above 80%.

Telemetry is a latest-snapshot concern. Vidyut does not persist telemetry
history, upload it to a service, or create a second polling endpoint. The
Relay may omit a metric when the operating system cannot provide it, and the
Android UI must render an explicit unavailable state rather than fabricate or
silently reuse an old value.

## Considered options

- Collect telemetry in the Android app through a second laptop HTTP endpoint.
- Collect telemetry in the laptop Relay and send it over the existing
  authenticated WebSocket.
- Persist telemetry history locally and render charts on the Home surface.

The accepted option keeps laptop-only facts close to their source, reuses the
already authenticated LAN connection, avoids another protocol surface, and
preserves the product's LAN-only privacy boundary. Snapshot-only data keeps
the first version operationally small and prevents Home from becoming a
monitoring-history surface.
