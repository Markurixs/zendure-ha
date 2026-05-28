# Zendure-HA Markurixs Fork — Implementierungsplan

**Stand:** 2026-05-28
**Upstream:** Zendure/Zendure-HA @ 8a0161f
**Branch:** fork-main
**Target:** Home Assistant 2026.5.4, Python 3.12.13, HAOS

## Markus's Setup (relevant für alle Patches)

- **14 Speicher-Devices im Cluster**: 2× Hyper2000, 5× AB2000, 4× AB2000X, 2× AB1000S, 1× Ace1500
- **P1 Meter**: `sensor.smartmeter_power_filtered` (ecotracker via MQTT, ~1.3s Update-Rate, 227 Updates/5min)
- **PV**: Hoymiles WR mit eigenem Zero-Export Addon (läuft parallel — Aufschaukel-Risiko)
- **Tarif**: Tibber (sensor.tibber_spot_price)
- **Bestehende Automation**: hyper2000_uberschussladen (wird durch Patches teils obsolet)

## Grundprinzipien

1. **Additive Patches zuerst** (brechen nichts) → riskante Kern-Änderungen danach
2. **Jeder Patch = 1 git commit** mit klarer Message, einzeln revertierbar
3. **Jede Welle: deploy → 24-48h beobachten → nächste Welle**
4. **Alle Defaults konservativ** — User kann via Number/Switch Entity später tunen
5. **Niemals Upstream-Funktionalität entfernen** — nur ergänzen/optional ein/aus
6. **Versionierung**: 1.3.1-fork.1, 1.3.1-fork.2, ... bis Upstream-Rebase nötig

---

## WELLE 1 — Additive Features (low risk)

### Patch A: Issue #1022 — Variables Target + Deadzone

**Problem:** Manager regelt jede Abweichung am P1-Sensor auf 0W. Verursacht permanente Mikro-Regelvorgänge (~90% davon unnötig). User HenryMoec misst 90% weniger Regelvorgänge mit Deadzone ±30W bei gleicher Qualität.

**Root Cause im Code:** `manager.py:360 _p1_changed()` triggert bei JEDER P1-Änderung Power-Distribution. Keine Deadzone-Logik existiert.

**Fix:**
1. Neue Konstanten in `const.py`:
   ```python
   class SmartMode:
       ...
       DEADZONE_DEFAULT = 50  # ±W around target (issue #1022)
       TARGET_DEFAULT = 0     # P1 target offset (issue #1022)
   ```

2. Neue Konfig-Entities in `manager.py` `loadDevices()`:
   ```python
   self.deadzone = ZendureRestoreNumber(
       self, "deadzone", None, None, "W", "power",
       500, 0, NumberMode.BOX, True
   )  # 0-500W, default 50
   self.p1_target = ZendureRestoreNumber(
       self, "p1_target", None, None, "W", "power",
       2000, -2000, NumberMode.BOX, True
   )  # -2000 to +2000W, default 0
   ```
   Default-Initialisierung im RestoreNumber-Constructor sicherstellen.

3. In `_p1_changed()` direkt nach Float-Konvertierung:
   ```python
   # Apply target offset (#1022)
   target = int(self.p1_target.asNumber)
   p1_effective = p1 - target

   # Apply deadzone (#1022)
   deadzone = int(self.deadzone.asNumber)
   if abs(p1_effective) <= deadzone:
       # In deadzone — no control action, but still update history
       self.p1_history.append(0)  # treat as zero for stddev calc
       return
   p1 = p1_effective
   ```

**Risk Assessment:**
- ✅ Additiv, defaults = altes Verhalten (deadzone=0, target=0 wenn User nicht ändert)
- ⚠️ Mit Default=50W: spürbare Reduktion der Regelvorgänge, minimaler Bezugs-Anstieg
- Test: 24h beobachten ob Tibber-Pulse-Bezug sich verschlechtert

**Acceptance:**
- [ ] Number.zendure_manager_deadzone existiert in HA, default 50
- [ ] Number.zendure_manager_p1_target existiert, default 0
- [ ] Logs zeigen "P1 in deadzone, skipping" wenn |p1| ≤ deadzone
- [ ] Bei deadzone=0: identisches Verhalten zu Upstream (Regression-Check)
- [ ] Anzahl `power_charge/discharge` Calls in 1h reduziert um >70% bei deadzone=50

---

### Patch B: Tibber Native Integration

**Problem:** Issue #694 (Tibber Charge in Cheapest Hours) wurde "Not planned" geschlossen. Aber `CONF_PRICE = "price"` existiert bereits in const.py — half-implemented.

**Fix:**
1. `config_flow.py`: Neues optionales Feld "Price Sensor" hinzufügen (Entity Selector, domain=sensor)

2. `const.py` erweitern:
   ```python
   class SmartMode:
       ...
       CHEAP_HOURS_DEFAULT = 4   # Top N cheapest hours per 24h
       PRICE_THRESHOLD_DEFAULT = 15  # ct/kWh — charge if price below
   ```

3. `manager.py` neue Entities:
   ```python
   self.cheap_hours_count = ZendureRestoreNumber(
       self, "cheap_hours_count", None, None, "h", None,
       12, 0, NumberMode.BOX, True
   )  # 0-12 h, default 4
   self.cheap_price_threshold = ZendureRestoreNumber(
       self, "cheap_price_threshold", None, None, "ct/kWh", None,
       50, 0, NumberMode.BOX, True
   )  # default 15 ct
   self.cheap_hours_active = ZendureSensor(
       self, "cheap_hours_active", None, None, None, None, 0
   )  # binary 0/1
   self.current_price = ZendureSensor(
       self, "current_price", None, "ct/kWh", "monetary", "measurement", 2
   )
   ```

4. Periodische Berechnung in `_async_update_data()`:
   - Wenn `CONF_PRICE` configured: lese current price + future prices
   - Tibber-Spezifik: future Stunden sind in `attributes.tomorrow`/`today` arrays
   - Berechne: ist aktuelle Stunde unter den N billigsten ODER Preis < threshold
   - Setze `cheap_hours_active` sensor

5. **NUR Sensor-Bereitstellung in Welle 1** — Mode-Auto-Switch (Cheap → MATCHING_CHARGE) kommt in eigener Automation, die User selbst baut, ODER als optionaler Switch in Welle 3.

**Risk Assessment:**
- ✅ Komplett additiv, keine Verhaltens-Änderung wenn Price-Sensor nicht configured
- ⚠️ Tibber-API-Format-Annahmen: muss robust gegen unavailable/unknown sein

**Acceptance:**
- [ ] Config-Flow zeigt Price-Sensor-Feld
- [ ] Sensor.zendure_manager_current_price zeigt korrekten ct/kWh-Wert
- [ ] Sensor.zendure_manager_cheap_hours_active = 1 wenn aktuelle Stunde in Top-N billigsten
- [ ] Bei Price-Sensor=None: keine Logs/Fehler

---

### Welle 1 Deployment

```bash
# Auf Markus's HA (192.168.44.250):
cp -r /config/custom_components/zendure_ha /config/custom_components/zendure_ha.bak.upstream_v1.3.1
rsync -av ~/work/zendure-ha-markus/custom_components/zendure_ha/ root@192.168.44.250:/config/custom_components/zendure_ha/
ssh root@192.168.44.250 "ha core check"  # MUSS clean sein
ssh root@192.168.44.250 "ha core restart"  # ~30s downtime
# Verify: ssh ... "ha core logs --lines 200 2>&1 | grep -iE 'zendure|error' | tail -50"
```

**Test-Plan 24h:**
- DB-Query alle 4h: Wie oft `power_charge/discharge` aufgerufen?
- Tibber-Pulse-Wert: Bezug delta < 0.5 kWh/d Verschlechterung?
- Cheap-Hours-Sensor: korrekt 4h aktiv pro Tag?

---

## WELLE 2 — Kerncode-Änderungen (medium risk)

### Patch C: Issue #1320 — Zero Export bei >1000W

**Problem:** Bei Lastsprüngen >1000W kompensiert Smart Mode nicht mehr — bleiben Rest-Bezüge stehen. Tritt seit v1.3.0 auf.

**Root Cause im Code:** Mehrere Faktoren in `manager.py`:
1. Line 60: `TIMEFAST = 2.2` — nach "fast detection" wird 2.2s lang nur History updated, kein Power-Push
2. Line 64: `P1_STDDEV_FACTOR = 3.5`, `P1_STDDEV_MIN = 15` — Threshold zu hoch bei großen Loads
3. Line 526-548 `power_charge`: Distribution-Loop limitiert per `pwr_max` aber nicht per Cluster-Total
4. Bei 14 Devices: jedes hat ~1-2s MQTT-Latency → Cluster-Reaktionszeit aggregiert

**Fix (mehrteilig):**

1. **Adaptive TIMEFAST** in `_p1_changed`:
   ```python
   # Issue #1320: At large p1 spikes, shorten the lockout
   abs_p1 = abs(p1)
   if abs_p1 > 1500:
       fast_timeout = SmartMode.TIMEFAST_LARGE  # 0.5s
   elif abs_p1 > 500:
       fast_timeout = SmartMode.TIMEFAST_MED    # 1.0s
   else:
       fast_timeout = SmartMode.TIMEFAST        # 2.2s (current)
   ```
   Neue Konstanten:
   ```python
   TIMEFAST = 2.2
   TIMEFAST_MED = 1.0  # for 500-1500W spikes
   TIMEFAST_LARGE = 0.5  # for >1500W spikes (#1320)
   ```

2. **Adaptive STDDEV-Threshold**: Bei großen Lasten ist 15W stddev nichts. Skalieren mit Last:
   ```python
   stddev_min = max(SmartMode.P1_STDDEV_MIN, abs_p1 * 0.02)  # 2% of load as min stddev
   ```

3. **Pre-emptive Cluster-Sync bei großen Spikes**: Vor `powerChanged()` für jeden Device einmal `await d.power_get()` pushen wenn `abs_p1 > 1500` und nicht innerhalb der letzten 5s → reduziert Latenz-Kaskade.

4. **Defensives Setpoint-Capping** in `power_discharge` (Line 590):
   ```python
   # Issue #1320: Make sure we don't undershoot — if discharge_limit < setpoint,
   # log warning so user knows cluster is saturated
   if self.discharge_limit < setpoint:
       _LOGGER.warning("Cluster discharge saturated: limit=%sW setpoint=%sW devices=%d",
                       self.discharge_limit, setpoint, len(self.discharge))
   ```

**Risk Assessment:**
- ⚠️⚠️ Greift in Kern-Regellogik ein, betrifft 14 Devices gleichzeitig
- ⚠️ Adaptive TIMEFAST kann CPU-Load auf HA erhöhen (mehr Updates/s)
- ⚠️ Bei falscher Stddev-Skalierung: noch instabileres Regelverhalten
- **Mitigation:** Switch.zendure_manager_adaptive_timing — User kann auf Upstream-Verhalten zurückschalten

**Acceptance:**
- [ ] Bei simuliertem Lastsprung +2000W: Reaktion in <2s, Bezug abgebaut in <4s
- [ ] Switch zum Deaktivieren der adaptiven Timings vorhanden
- [ ] Logs sind nicht spammig (<1 log/s bei normaler Last)
- [ ] CPU-Load HA Prozess: <5% Anstieg

---

### Patch D: Issue #1103 — P1 Sensor Stale Detection

**Problem:** Wenn P1-Sensor nicht updated, hängt Manager — bleibt bei letztem Wert, manual mode broken, off mode zeigt Reststrom an. Edelfant beschreibt das bei seinem Helper-Sensor (der bei Mode=off bewusst nicht updated).

**Root Cause:** Power-Logic hängt komplett an `_p1_changed` Event. `_async_update_data` läuft alle 60s, aber tut nichts mit Power.

**Fix:**

1. Track last P1 timestamp:
   ```python
   self.p1_last_update: datetime = datetime.min
   ```
   In `_p1_changed` setzen: `self.p1_last_update = datetime.now()`

2. In `_async_update_data` (läuft alle 60s):
   ```python
   # Issue #1103: detect stale P1 sensor
   age = (datetime.now() - self.p1_last_update).total_seconds()
   if age > SmartMode.P1_STALE_TIMEOUT:  # default 120s
       _LOGGER.warning("P1 sensor stale (%ss), forcing manager power reset", int(age))
       # Force power=0 and operation state update so dashboards reflect reality
       self.power.update_value(0)
       self.operationstate.update_value(ManagerState.OFF.value)
       # In MANUAL mode: still apply manual setpoint
       if self.operation == ManagerMode.MANUAL:
           setpoint = int(self.manualpower.asNumber)
           await self.powerChanged(0, False, datetime.now())  # pretend p1=0
   ```

3. In `update_operation()` bei mode→OFF: explizit `power=0` setzen statt warten auf nächstes P1:
   ```python
   case ManagerMode.OFF:
       self.power.update_value(0)
       self.operationstate.update_value(ManagerState.OFF.value)
       for d in self.devices:
           await d.power_off()
   ```

**Risk Assessment:**
- ✅ Defensiv, nur Edge-Cases
- ⚠️ Force-Update könnte bei kurzen MQTT-Hängern false-positive — Timeout konservativ (120s) wählen

**Acceptance:**
- [ ] Mode→Off: power Sensor sofort = 0, nicht erst nach nächstem P1
- [ ] P1-Sensor 3min unavailable: Warning im Log, manager state = OFF
- [ ] Manual mode: manuelle Power wird gesendet auch wenn P1 stale

---

### Welle 2 Deployment

Wie Welle 1, aber mit längerem Test (48h) und Monitoring von:
- Cluster-Sync-Latenz bei Lastsprüngen
- Anzahl MQTT-Errors in Logs
- CPU-Load HA

**Rollback-Trigger:**
- Mehr Bezug-kWh als vor Patch C
- CPU-Load >10% höher
- MQTT-Disconnects > 2/h

---

## WELLE 3 — Edge Cases

### Patch E: Issue #1040 — Smart Discharge bei externer PV-Einspeisung

**Problem:** Im Modus MATCHING_DISCHARGE entlädt der Akku auch wenn P1 negativ ist (Einspeisung von externer PV) — sollte stattdessen die Akkus laden.

**Root Cause** `manager.py:480-482`:
```python
case ManagerMode.MATCHING_DISCHARGE:
    # Only discharge, do nothing if setpoint is negative
    await self.power_discharge(max(0, setpoint))
```
Logik ist "nur entladen, ignoriere negative" — aber wenn p1 < 0 (Einspeisung) wird trotzdem `discharge(0)` gerufen, was bei manchen Devices nicht sauber stoppt.

**Fix:**
1. Pre-check: bei `setpoint < 0` (externer PV-Überschuss) komplett alle Devices in idle:
   ```python
   case ManagerMode.MATCHING_DISCHARGE:
       if setpoint < -SmartMode.POWER_START:
           # External PV surplus — actively idle all devices, do not "discharge 0"
           # which can leak power on some devices
           for d in self.devices:
               await d.power_off() if d.electricLevel.asInt >= 100 else await d.power_charge(0)
           self.operationstate.update_value(ManagerState.IDLE.value)
       else:
           await self.power_discharge(max(0, setpoint))
   ```

2. Optional: Neuer ManagerMode `MATCHING_DISCHARGE_OR_CHARGE` der zwischen den beiden umschaltet abhängig vom Vorzeichen. Aber das ist quasi MATCHING — vielleicht nur ein Switch "auto_charge_on_surplus".

**Risk Assessment:**
- ⚠️ Power-off auf alle Devices ist invasiv, kann Cluster-State durcheinanderbringen
- **Alternative**: Nur Discharge-Set auf -10 statt 0 (wie schon in power_charge Line 515 gemacht)

**Acceptance:**
- [ ] In MATCHING_DISCHARGE bei externer PV (p1<-100W): Akkus laden statt entladen ODER stehen sauber still
- [ ] Beim Übergang p1: -200 → +200 keine Spikes

---

## Was ich NICHT fixe (bewusst)

- **Cloud-MQTT-Latenz**: nicht im HA-Code, nicht änderbar
- **Hoymiles-Konflikt**: vorerst parallel laufen lassen, User-Entscheidung
- **Cheap-Hours-Auto-Switch**: liefere nur Sensor, User baut Automation in HA (mehr Flexibilität)
- **Power Distribution Strategy** (Wiki): scheint zu funktionieren, nicht anfassen

## Versions-Bumping

- `manifest.json` version: "1.3.1-fork.1" für Welle 1 Release
- "1.3.1-fork.2" nach Welle 2
- "1.3.1-fork.3" nach Welle 3
- Bei Upstream-Release: rebase auf upstream/master, version → "1.3.x-fork.1"

## Backup-Strategie auf HA

Vor jedem Deployment:
```bash
cp -r /config/custom_components/zendure_ha \
      /config/custom_components/zendure_ha.bak.<welle>_<timestamp>
```

Bei Problemen: Welle-Backup zurückrollen, `ha core restart`, fertig.

## Tracking

Jeder Patch = 1 commit auf fork-main:
- `feat(deadzone): add P1 deadzone + target offset (#1022)`
- `feat(tibber): add native price sensor support`
- `fix(zero-export): adaptive timing for large load spikes (#1320)`
- `fix(p1-stale): detect and handle stale P1 sensor (#1103)`
- `fix(matching-discharge): handle external PV surplus correctly (#1040)`

Plus 1 commit `chore: bump version to 1.3.1-fork.X` pro Release.
