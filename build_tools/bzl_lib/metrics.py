"""
Metrics library for bzl.
This will log timing metrics to multiple locations, including stderr and (later) logpusher
"""
import contextlib
import os
import sys
import time

from collections import defaultdict, namedtuple
from typing import Any, Callable, DefaultDict, Dict, Iterator, List, Optional, Set


class StatsError(Exception):
    pass


class Stats(object):
    def __init__(self):
        # type: () -> None
        self.mode = "_bzl_unknown"
        self.extra_attributes_map = {}  # type: Dict[str, str]
        self.recorded_timers = []  # type: List[Timer]
        self.cumulative_rates = defaultdict(int)  # type: DefaultDict[str, int]
        self.gauges = []  # type: List[Gauge]
        self.seen_stats_keys = set()  # type: Set[str]
        self.error_type = None  # type: Optional[str]
        self.error_text = None  # type: Optional[str]
        self.reported = False


_stats = Stats()


class Timer(object):
    def __init__(self, name, interval_ms=None):
        # type: (str, Optional[int]) -> None
        if not name.endswith("_ms"):
            raise StatsError("By convention, Timer names must end with _ms")
        self.name = name
        self.start_ms = int(time.time() * 1000)
        self.interval_ms = interval_ms

    def start(self):
        # type: () -> None
        self.start_ms = int(time.time() * 1000)

    def stop(self):
        # type: () -> None
        self.interval_ms = int(time.time() * 1000) - self.start_ms

    def get_interval_ms(self):
        # type: () -> int
        if self.interval_ms is None:
            return int(time.time() * 1000) - self.start_ms
        return self.interval_ms

    def __enter__(self):
        # type: () -> Timer
        self.start()
        return self

    def __exit__(self, *args):
        # type: (*Any) -> None
        self.stop()

    def __str__(self):
        # type: () -> str
        return "%s: %dms" % (self.name, self.get_interval_ms())


Gauge = namedtuple("Gauge", ["key", "value"])


class GenMetrics(object):
    """Helper class to report how long `bzl gen` generators take to run,
    not including any recursive calls to other generators. We expect
    recursive calls to generators to pass through `gazel.regenerate_build_files`.
    """

    def __init__(self):
        # type: () -> None
        self.generator_queue = []  # type: List[str]
        self.timer = None  # type: Optional[Timer]

    def _create_and_start_timer_for_generator(self, generator_name):
        # type: (str) -> None
        timer_name = "bzl_gen_{}_ms".format(generator_name)
        self.timer = Timer(timer_name)
        self.timer.start()

    def _stop_current_timer_and_update(self, is_exit=True):
        # type: (bool) -> None
        assert self.timer is not None
        self.timer.stop()
        log_cumulative_rate(self.timer.name, self.timer.get_interval_ms())
        # Do not increment the _called metric if entering a recursive call.
        if is_exit:
            log_cumulative_rate(self.timer.name[:-3] + "_called", 1)

    def enter_generator(self, generator_name):
        # type: (str) -> None
        if self.generator_queue:
            self._stop_current_timer_and_update(is_exit=False)
        self.generator_queue.append(generator_name)
        self._create_and_start_timer_for_generator(generator_name)

    def exit_generator(self):
        # type: () -> None
        self._stop_current_timer_and_update()
        self.generator_queue.pop()
        if self.generator_queue:
            prev_generator = self.generator_queue[-1]
            self._create_and_start_timer_for_generator(prev_generator)


_generator_metrics = GenMetrics()


@contextlib.contextmanager
def generator_metric_context(generator_name):
    # type: (str) -> Iterator[None]
    _generator_metrics.enter_generator(generator_name)
    try:
        yield
    finally:
        _generator_metrics.exit_generator()


def create_and_register_timer(name, interval_ms=None):
    # type: (str, Optional[int]) -> Timer
    timer = Timer(name, interval_ms)
    if timer.name in _stats.seen_stats_keys:
        raise StatsError("duplicate stats name {}".format(timer.name))
    _stats.seen_stats_keys.add(timer.name)
    _stats.recorded_timers.append(timer)
    return timer


def set_gauge(key, value):
    # type: (str, int) -> None
    if key in _stats.seen_stats_keys:
        raise StatsError("duplicate stats name {}".format(key))
    _stats.seen_stats_keys.add(key)
    _stats.gauges.append(Gauge(key=key, value=value))


def log_cumulative_rate(key, value):
    # type: (str, int) -> None
    if key in _stats.seen_stats_keys and key not in _stats.cumulative_rates:
        raise StatsError("non-cumulative stat {} already exists".format(key))
    _stats.seen_stats_keys.add(key)
    _stats.cumulative_rates[key] += value


def set_mode(new_mode):
    # type: (str) -> None
    _stats.mode = new_mode


def set_extra_attributes(key, value):
    # type: (str, str) -> None
    _stats.extra_attributes_map[key] = value


def has_error():
    # type: () -> bool
    return _stats.error_type is not None


def set_error(error_type, error_text):
    # type: (str, str) -> None
    _stats.error_type = error_type
    _stats.error_text = error_text


def report_metrics():
    # type: () -> None
    """
    Report all metrics recorded so far. This should only be called at the end of a program's
    lifetime.
    """
    if _stats.reported:
        return
    for k in os.environ:
        # pass through a few extra attributes, used for devbox stats collection in
        # //devbox/edit-refresh:benchmark-edit-refresh
        if k.startswith("BZL_METRICS_EXTRA_ATTR_"):
            stats_key = k[len("BZL_METRICS_EXTRA_ATTR_") :].lower()
            set_extra_attributes(stats_key, os.environ[k])
    _stats.reported = True
    if os.getenv("BZL_DEBUG"):
        if _stats.recorded_timers:
            print("Timers:", file=sys.stderr)
            for timer in _stats.recorded_timers:
                print("    {}".format(timer), file=sys.stderr)
        if _stats.gauges:
            print("Gauges:", file=sys.stderr)
            for (key, value) in _stats.gauges:
                print("    {}: {}".format(key, value), file=sys.stderr)
        if _stats.cumulative_rates:
            print("Cumulative rates:", file=sys.stderr)
            for (key, value) in _stats.cumulative_rates.items():
                print("    {}: {}".format(key, value), file=sys.stderr)
        if _stats.extra_attributes_map:
            print("Extra Attributes:", file=sys.stderr)
            for key in sorted(_stats.extra_attributes_map.keys()):
                print(
                    "    {}: {}".format(key, _stats.extra_attributes_map[key]),
                    file=sys.stderr,
                )
    logpusher_data = {
        "bzl": {
            "cmd": sys.argv,
            "mode": _stats.mode,
            "extra_attributes": _stats.extra_attributes_map,
        },
        "metrics": {},
    }  # type: Dict[str, Any]
    if has_error():
        logpusher_data["error"] = {"text": _stats.error_text, "type": _stats.error_type}
    for timer in _stats.recorded_timers:
        logpusher_data["metrics"][timer.name] = timer.get_interval_ms()
    for (key, value) in _stats.gauges:
        logpusher_data["metrics"][key] = value
    for (key, value) in _stats.cumulative_rates.items():
        logpusher_data["metrics"][key] = value
    if _write_metrics is not None:
        _write_metrics("bzl", logpusher_data)


_write_metrics = None  # type: Optional[Callable[[str, Dict[str, Any]], None]]


def set_write_metrics(write_metrics):
    # type: (Callable[[str, Dict[str, Any]], None]) -> None
    global _write_metrics
    _write_metrics = write_metrics


@contextlib.contextmanager
def main_metrics_scope():
    # type: () -> Iterator[None]
    create_and_register_timer("total_duration_ms").start()
    try:
        yield
    except SystemExit as e:
        if not has_error() and e.code != 0:
            set_error("unknown", str(e))
        raise
    except:  # intentionally bare
        # if no error was set until this point, set an unknown error with the exception
        if not has_error():
            exc_type, value = sys.exc_info()[:2]
            set_error("unknown", "{}: {}".format(exc_type, value))
        raise
    finally:
        # register the report function for regular exits. For functions
        # that use exec syscalls, build_tools.exec_wrapper will handle the reporting
        report_metrics()
