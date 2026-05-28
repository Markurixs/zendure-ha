# Zendure Home Assistant Integration — Markurixs Fork

[![hacs][hacsbadge]][hacs] [![License][license-shield]](LICENSE)

A personal fork of the [Zendure Home Assistant Integration][upstream] with
quality-of-life patches for multi-device clusters and dynamic-tariff users.

This fork stays drop-in compatible with upstream: existing configurations,
entities, and automations keep working. The patches are either opt-in or
default-conservative — turning all new knobs off reproduces upstream
behaviour bit-for-bit.

## What this fork adds

| # | Patch | Default | Issue |
|---|---|---|---|
| 1 | P1 deadzone + target offset (cuts ~90% of micro-regulation cycles) | 50W deadzone | [#1022][i1022] |
| 2 | Native dynamic-tariff support (Tibber/Nordpool/aWATTar): exposes `current_price` + `cheap_hours_active` sensors | inactive until a price sensor is configured | [#694][i694] |
| 3 | Opt-in adaptive timing for large P1 spikes (sub-second response above 1.5 kW) | OFF | [#1320][i1320] |
| 4 | P1 sensor stale-detection (forces `power=0` when the meter goes silent or unavailable) | always on, 120s timeout | [#1103][i1103] |
| 5 | Logs external-PV surplus in `MATCHING_DISCHARGE` mode | informational only | [#1040][i1040] |

All patches are tagged with `Issue #NNNN` comments in the source so an
upstream rebase stays straightforward.

### New entities

- `number.zendure_manager_deadzone` — 0..500 W, default 50
- `number.zendure_manager_p1_target` — −2000..+2000 W, default 0
- `number.zendure_manager_adaptive_timing` — 0/1, default 0 (opt-in)
- `number.zendure_manager_cheap_hours_count` — 0..12, default 4
- `number.zendure_manager_cheap_price_threshold` — 0..100 ct/kWh, default 15
- `sensor.zendure_manager_current_price` — current electricity price
- `sensor.zendure_manager_cheap_hours_active` — 0/1 flag for automations
- `sensor.zendure_manager_deadzone_skips_total` — cumulative skip counter

## Installation

### HACS (custom repository)

1. HACS → three-dot menu → **Custom repositories**
2. Add `https://github.com/Markurixs/zendure-ha` as type **Integration**
3. Search for *Zendure*, install the entry from `Markurixs/zendure-ha`
4. **Settings → Devices & Services → Add Integration → Zendure**

If you already had the upstream integration installed, uninstall it first
or HACS will refuse the custom one because of the conflicting domain.

### Manual

```bash
git clone https://github.com/Markurixs/zendure-ha.git
rsync -av --exclude='__pycache__' \
  zendure-ha/custom_components/zendure_ha/ \
  /config/custom_components/zendure_ha/
ha core restart
```

The repo also ships `deploy.sh` and `monitor.sh` for SSH-based deployment
against a Home Assistant OS instance — see the script headers for usage.

## Configuration

The standard config flow is unchanged. One field is added:

- **Electricity price sensor (optional)** — any sensor that exposes the
  current price as state. Tibber-style sensors that publish `today` /
  `tomorrow` attribute arrays with `{"total": <price>}` items are
  parsed automatically; other formats fall back to the simple threshold
  comparison.

To use dynamic-tariff charging, build your own automation on top of
`sensor.zendure_manager_cheap_hours_active` — that lets you combine
price with SoC, weather, or anything else.

## Minimum requirements

- Home Assistant 2025.5+

## Supported devices

Same as upstream: Ace1500, Aio2400, Hyper2000, Hub1200, Hub2000, SF800
(Pro/Plus), SF1600 AC+, SF2400 (AC/AC+/Pro), SuperBase V6400.

## Status

**DRAFT — not yet long-run validated.** The patches pass syntax and HACS
validation and have been reviewed for correctness, but they have not yet
been observed for 24h+ on a production cluster. Use the rollback path in
`deploy.sh` if anything misbehaves.

## Credits

Forked from [Zendure/Zendure-HA][upstream]. All upstream work, device
implementations, and the underlying architecture remain by the upstream
maintainers. This fork only adds the patches listed above.

## License

MIT — see [LICENSE](LICENSE).

[upstream]: https://github.com/Zendure/Zendure-HA
[hacs]: https://hacs.xyz/
[hacsbadge]: https://img.shields.io/badge/HACS-Custom-orange.svg?style=for-the-badge
[license-shield]: https://img.shields.io/github/license/Markurixs/zendure-ha.svg?style=for-the-badge
[i1022]: https://github.com/Zendure/Zendure-HA/issues/1022
[i694]: https://github.com/Zendure/Zendure-HA/issues/694
[i1320]: https://github.com/Zendure/Zendure-HA/issues/1320
[i1103]: https://github.com/Zendure/Zendure-HA/issues/1103
[i1040]: https://github.com/Zendure/Zendure-HA/issues/1040
