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

Home presents five telemetry metrics beneath the single `Send files` action:
battery and CPU temperature on the first row, memory and storage on the second
row, and CPU usage as a full-width third-row card. CPU usage is color-coded as
Low below 50%, Moderate from 50% through 80%, and High above 80%.

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
