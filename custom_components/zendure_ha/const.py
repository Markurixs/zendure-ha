"""Constants for Zendure."""

from datetime import timedelta
from enum import Enum

DOMAIN = "zendure_ha"

CONF_APPTOKEN = "token"
CONF_P1METER = "p1meter"
CONF_PRICE = "price"
CONF_MQTTLOG = "mqttlog"
CONF_MQTTLOCAL = "mqttlocal"
CONF_MQTTSERVER = "mqttserver"
CONF_SIM = "simulation"
CONF_MQTTPORT = "mqttport"
CONF_MQTTUSER = "mqttuser"
CONF_MQTTPSW = "mqttpsw"
CONF_WIFISSID = "wifissid"
CONF_WIFIPSW = "wifipsw"
CONF_AUTO_MQTT_USER = "auto_mqtt_user"

CONF_HAKEY = "C*dafwArEOXK"


class AcMode:
    INPUT = 1
    OUTPUT = 2


class DeviceState(Enum):
    OFFLINE = 0
    SOCEMPTY = 1
    INACTIVE = 2
    SOCFULL = 3
    ACTIVE = 4


class ManagerMode(Enum):
    OFF = 0
    MANUAL = 1
    MATCHING = 2
    MATCHING_DISCHARGE = 3
    MATCHING_CHARGE = 4
    STORE_SOLAR = 5


class ManagerState(Enum):
    IDLE = 0
    CHARGE = 1
    DISCHARGE = 2
    OFF = 3


class SmartMode:
    SOCFULL = 1
    SOCEMPTY = 2
    ZENSDK = 2
    CONNECTED = 10

    TIMEFAST = 2.2  # Fast update interval after significant change
    TIMEZERO = 4  # Normal update interval

    # Standard deviation thresholds for detecting significant changes
    P1_STDDEV_FACTOR = 3.5  # Multiplier for P1 meter stddev calculation
    P1_STDDEV_MIN = 15  # Minimum stddev value for P1 changes (watts)
    P1_MIN_UPDATE = timedelta(milliseconds=400)
    SETPOINT_STDDEV_FACTOR = 5.0  # Multiplier for power average stddev calculation
    SETPOINT_STDDEV_MIN = 50  # Minimum stddev value for power average (watts)

    HEMSOFF_TIMEOUT = 60  # Seconds before HEMS state is set to OFF if no updates are received

    POWER_START = 50  # Minimum Power (W) for starting a device
    POWER_TOLERANCE = 5  # Device-level power tolerance (W) before updating

    # Issue #1022: Deadzone around P1 target to reduce micro-regulations.
    # Symmetric band [target - DEADZONE_DEFAULT, target + DEADZONE_DEFAULT]
    # in which no power redistribution happens. Set to 0 for upstream behavior.
    DEADZONE_DEFAULT = 50  # ±W around target (issue #1022)
    DEADZONE_MAX = 500  # User-configurable ceiling
    TARGET_DEFAULT = 0  # P1 target offset in W (positive=allow draw, negative=push feed-in)
    TARGET_RANGE = 2000  # ± range exposed to user

    # Issue #1103: Stale P1 detection. If no P1 update for this many seconds,
    # the manager will force a power=0 update and warn.
    P1_STALE_TIMEOUT = 120

    # Issue #694: Native dynamic-tariff support. Reads a user-provided price
    # sensor (e.g. Tibber spot price) and exposes "cheap_hours_active" so the
    # user can build automations that switch the manager to MATCHING_CHARGE
    # during the cheapest N hours of the day.
    CHEAP_HOURS_DEFAULT = 4
    CHEAP_HOURS_MAX = 12
    CHEAP_PRICE_THRESHOLD_DEFAULT = 15
    CHEAP_PRICE_THRESHOLD_MAX = 100

    # Issue #1320: Adaptive timing for large P1 spikes. Opt-in via the
    # adaptive_timing Number entity (0=off=upstream behaviour, 1=on).
    # When ON: the TIMEFAST lockout is shortened for big spikes so the
    # cluster reacts faster instead of waiting the full TIMEFAST window.
    # Coexistence with external zero-export controllers (e.g. Hoymiles
    # zero-export addon) is risky — keep OFF unless this is the only
    # regulator on the grid bus.
    TIMEFAST_MED = 1.0
    TIMEFAST_LARGE = 0.5
    SPIKE_MED_THRESHOLD = 500
    SPIKE_LARGE_THRESHOLD = 1500
    STDDEV_SPIKE_FACTOR = 0.02
