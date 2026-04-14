"""Timer manager for start_timer/cancel_timer effects.

Manages named delayed timers for the YAML interpreter.
Uses QTimer for Qt event loop integration.
"""

from __future__ import annotations

from PySide6.QtCore import QTimer


class TimerManager:
    """Manages named timers with delayed callbacks."""

    _instance: TimerManager | None = None

    def __init__(self):
        self._timers: dict[str, QTimer] = {}

    @classmethod
    def shared(cls) -> TimerManager:
        if cls._instance is None:
            cls._instance = TimerManager()
        return cls._instance

    def start_timer(self, timer_id: str, delay_ms: int, callback) -> None:
        """Start a named timer that fires callback after delay_ms.

        If a timer with the same id already exists, it is cancelled first.
        """
        self.cancel_timer(timer_id)
        timer = QTimer()
        timer.setSingleShot(True)
        timer.timeout.connect(lambda: self._on_fire(timer_id, callback))
        timer.start(delay_ms)
        self._timers[timer_id] = timer

    def cancel_timer(self, timer_id: str) -> None:
        """Cancel a pending timer by ID."""
        timer = self._timers.pop(timer_id, None)
        if timer is not None:
            timer.stop()

    def _on_fire(self, timer_id: str, callback) -> None:
        self._timers.pop(timer_id, None)
        callback()
