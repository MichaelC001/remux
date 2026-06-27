#!/usr/bin/env python3
"""Summarize Remux topology action flow segments from unified log exports."""

from __future__ import annotations

import argparse
import re
import statistics
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable


FLOW_RE = re.compile(
    r"Remux flow t=(?P<timestamp>\d+) "
    r"flow=(?P<flow>tmux\.(?:newWindow|splitPane)) "
    r"event=(?P<event>[^ ]+) "
    r"since_ms=(?P<since>[0-9.]+)"
    r"(?P<fields>.*)$"
)

NATIVE_SURFACE_INIT_RE = re.compile(
    r"Ghostty surfaceInit t=(?P<timestamp>-?\d+) "
    r"seq=(?P<sequence>\d+) "
    r"phase=(?P<phase>[^ ]+) "
    r"duration_ns=(?P<duration_ns>\d+)"
    r"(?: .*?context=(?P<context>[^ ]+) "
    r"backing=(?P<backing>[^ ]+))?"
)


@dataclass(frozen=True)
class FlowEvent:
    timestamp: int
    flow: str
    event: str
    since_ms: float
    source: str
    fields: tuple[tuple[str, str], ...] = ()

    def field(self, name: str) -> str | None:
        return dict(self.fields).get(name)


@dataclass(frozen=True)
class NativeSurfaceInitEvent:
    timestamp: int
    sequence: int
    phase: str
    duration_ms: float
    context: str
    backing: str
    source: str


@dataclass
class FlowInstance:
    flow: str
    started_at: int
    events: list[FlowEvent]


@dataclass(frozen=True)
class Segment:
    name: str
    start: Callable[[FlowInstance], FlowEvent | None]
    end: Callable[[FlowInstance], FlowEvent | None]
    pairs: Callable[[FlowInstance], list[tuple[FlowEvent | None, FlowEvent | None]]] | None = None


@dataclass(frozen=True)
class CountMetric:
    name: str
    start: Callable[[FlowInstance], FlowEvent | None]
    end: Callable[[FlowInstance], FlowEvent | None]
    predicate: Callable[[str], bool]


def first_event(
    instance: FlowInstance,
    predicate: Callable[[str], bool],
) -> FlowEvent | None:
    for event in instance.events:
        if predicate(event.event):
            return event
    return None


def exact(name: str) -> Callable[[str], bool]:
    return lambda event: event == name


def prefix(value: str) -> Callable[[str], bool]:
    return lambda event: event.startswith(value)


def any_of(*names: str) -> Callable[[str], bool]:
    expected = set(names)
    return lambda event: event in expected


def latest_event(
    instance: FlowInstance,
    predicate: Callable[[str], bool],
) -> FlowEvent | None:
    matched = [event for event in instance.events if predicate(event.event)]
    if not matched:
        return None
    return max(matched, key=lambda event: event.timestamp)


def first_event_after(
    instance: FlowInstance,
    anchor: FlowEvent,
    predicate: Callable[[str], bool],
) -> FlowEvent | None:
    for event in instance.events:
        if event.timestamp >= anchor.timestamp and predicate(event.event):
            return event
    return None


def latest_event_after(
    instance: FlowInstance,
    anchor: FlowEvent,
    predicate: Callable[[str], bool],
) -> FlowEvent | None:
    matched = [
        event
        for event in instance.events
        if event.timestamp >= anchor.timestamp and predicate(event.event)
    ]
    if not matched:
        return None
    return max(matched, key=lambda event: event.timestamp)


def first_event_between(
    instance: FlowInstance,
    start: FlowEvent,
    end: FlowEvent,
    predicate: Callable[[str], bool],
) -> FlowEvent | None:
    for event in instance.events:
        if start.timestamp <= event.timestamp <= end.timestamp and predicate(event.event):
            return event
    return None


def latest_event_between(
    instance: FlowInstance,
    start: FlowEvent,
    end: FlowEvent,
    predicate: Callable[[str], bool],
) -> FlowEvent | None:
    matched = [
        event
        for event in instance.events
        if start.timestamp <= event.timestamp <= end.timestamp and predicate(event.event)
    ]
    if not matched:
        return None
    return max(matched, key=lambda event: event.timestamp)


def after_event(
    anchor: Callable[[FlowInstance], FlowEvent | None],
    predicate: Callable[[str], bool],
) -> Callable[[FlowInstance], FlowEvent | None]:
    def find(instance: FlowInstance) -> FlowEvent | None:
        anchor_event = anchor(instance)
        if anchor_event is None:
            return None
        return first_event_after(instance, anchor_event, predicate)

    return find


def latest_after_event(
    anchor: Callable[[FlowInstance], FlowEvent | None],
    predicate: Callable[[str], bool],
) -> Callable[[FlowInstance], FlowEvent | None]:
    def find(instance: FlowInstance) -> FlowEvent | None:
        anchor_event = anchor(instance)
        if anchor_event is None:
            return None
        return latest_event_after(instance, anchor_event, predicate)

    return find


def topology_installed(instance: FlowInstance) -> FlowEvent | None:
    return first_event(instance, exact("registry.topology.installed"))


def after_topology(predicate: Callable[[str], bool]) -> Callable[[FlowInstance], FlowEvent | None]:
    return after_event(topology_installed, predicate)


def latest_after_topology(predicate: Callable[[str], bool]) -> Callable[[FlowInstance], FlowEvent | None]:
    return latest_after_event(topology_installed, predicate)


def process_output_end(instance: FlowInstance) -> FlowEvent | None:
    return first_event(instance, prefix("tmux.signal.host.pump.processOutput.end."))


def tmux_response(instance: FlowInstance) -> FlowEvent | None:
    return first_event(instance, prefix("tmux.response."))


QUERY_KINDS = (
    "tmux_version",
    "list_windows",
    "pane_state",
    "pane_metadata",
    "pane_history",
    "pane_visible",
    "pane_pending_output",
)


def query_send(kind: str) -> Callable[[FlowInstance], FlowEvent | None]:
    return lambda flow: first_event(flow, exact(f"tmux.query.{kind}.send"))


def query_receive(kind: str) -> Callable[[FlowInstance], FlowEvent | None]:
    return after_event(query_send(kind), exact(f"tmux.query.{kind}.response.receive"))


def query_processed(kind: str) -> Callable[[FlowInstance], FlowEvent | None]:
    return after_event(
        query_receive(kind),
        exact(f"tmux.query.{kind}.response.processed"),
    )


def query_events_by_sequence(
    instance: FlowInstance,
    event_name: str,
) -> dict[str, FlowEvent]:
    events: dict[str, FlowEvent] = {}
    for event in instance.events:
        if event.event != event_name:
            continue
        sequence = event.field("sequence")
        if sequence is None:
            continue
        events.setdefault(sequence, event)
    return events


def sorted_query_sequences(events: dict[str, FlowEvent]) -> list[str]:
    def sort_key(sequence: str) -> tuple[int, int | str]:
        try:
            return (0, int(sequence))
        except ValueError:
            return (1, sequence)

    return sorted(events, key=sort_key)


def query_event_pairs(
    kind: str,
    start_phase: str,
    end_phase: str,
) -> Callable[[FlowInstance], list[tuple[FlowEvent | None, FlowEvent | None]]]:
    start_event_name = f"tmux.query.{kind}.{start_phase}"
    end_event_name = f"tmux.query.{kind}.{end_phase}"

    def pairs(instance: FlowInstance) -> list[tuple[FlowEvent | None, FlowEvent | None]]:
        starts = query_events_by_sequence(instance, start_event_name)
        ends = query_events_by_sequence(instance, end_event_name)
        return [(starts[sequence], ends.get(sequence)) for sequence in sorted_query_sequences(starts)]

    return pairs


def query_roundtrip_segments() -> list[Segment]:
    segments: list[Segment] = []
    for kind in QUERY_KINDS:
        send = query_send(kind)
        receive = query_receive(kind)
        processed = query_processed(kind)
        segments.extend(
            [
                Segment(
                    f"query.{kind}.send->response_receive",
                    send,
                    receive,
                    query_event_pairs(kind, "send", "response.receive"),
                ),
                Segment(
                    f"query.{kind}.response_receive->response_processed",
                    receive,
                    processed,
                    query_event_pairs(kind, "response.receive", "response.processed"),
                ),
                Segment(
                    f"query.{kind}.send->response_processed",
                    send,
                    processed,
                    query_event_pairs(kind, "send", "response.processed"),
                ),
            ]
        )
    return segments


def runtime_callback_entry(instance: FlowInstance) -> FlowEvent | None:
    return after_event(
        process_output_end,
        any_of(
            "runtime.callback.createSurfaceTree.entry",
            "runtime.callback.createSurface.entry",
        ),
    )(instance)


def runtime_wakeup_entry(instance: FlowInstance) -> FlowEvent | None:
    response = tmux_response(instance)
    callback = runtime_callback_entry(instance)
    if response is None or callback is None:
        return None
    return latest_event_between(
        instance,
        response,
        callback,
        exact("runtime.wakeup.entry"),
    )


def runtime_wakeup_main_actor_schedule(instance: FlowInstance) -> FlowEvent | None:
    entry = runtime_wakeup_entry(instance)
    callback = runtime_callback_entry(instance)
    if entry is None or callback is None:
        return None
    return first_event_between(
        instance,
        entry,
        callback,
        exact("runtime.wakeup.mainActor.schedule"),
    )


def runtime_wakeup_main_actor_begin(instance: FlowInstance) -> FlowEvent | None:
    schedule = runtime_wakeup_main_actor_schedule(instance)
    callback = runtime_callback_entry(instance)
    if schedule is None or callback is None:
        return None
    return first_event_between(
        instance,
        schedule,
        callback,
        exact("runtime.wakeup.mainActor.begin"),
    )


def runtime_wakeup_app_tick_begin(instance: FlowInstance) -> FlowEvent | None:
    begin = runtime_wakeup_main_actor_begin(instance)
    callback = runtime_callback_entry(instance)
    if begin is None or callback is None:
        return None
    return first_event_between(
        instance,
        begin,
        callback,
        exact("runtime.wakeup.appTick.begin"),
    )


def runtime_wakeup_app_tick_end(instance: FlowInstance) -> FlowEvent | None:
    return after_event(
        runtime_wakeup_app_tick_begin,
        exact("runtime.wakeup.appTick.end"),
    )(instance)


def runtime_callback_main_actor_schedule(instance: FlowInstance) -> FlowEvent | None:
    return after_event(
        runtime_callback_entry,
        any_of(
            "runtime.callback.createSurfaceTree.mainActor.schedule",
            "runtime.callback.createSurface.mainActor.schedule",
        ),
    )(instance)


def runtime_callback_main_actor_begin(instance: FlowInstance) -> FlowEvent | None:
    return after_event(
        runtime_callback_entry,
        any_of(
            "runtime.callback.createSurfaceTree.mainActor.begin",
            "runtime.callback.createSurface.mainActor.begin",
        ),
    )(instance)


def registry_callback_begin(instance: FlowInstance) -> FlowEvent | None:
    anchor = runtime_callback_entry(instance) or process_output_end(instance)
    if anchor is None:
        return None
    return first_event_after(
        instance,
        anchor,
        any_of("registry.createSurfaceTree.begin", "registry.createSurface.begin"),
    )


def registry_callback_event(name: str) -> Callable[[FlowInstance], FlowEvent | None]:
    def find(instance: FlowInstance) -> FlowEvent | None:
        start = registry_callback_begin(instance)
        end = topology_installed(instance)
        if start is None or end is None:
            return None
        return first_event_between(instance, start, end, exact(name))

    return find


registry_debug_update_begin = registry_callback_event("registry.debugSummary.update.begin")
registry_debug_update_end = registry_callback_event("registry.debugSummary.update.end")
registry_notify_begin = registry_callback_event("registry.notifyChanged.begin")
registry_notify_end = registry_callback_event("registry.notifyChanged.end")
registry_managed_create_begin = registry_callback_event("registry.managedSurface.create.begin")
registry_managed_create_end = registry_callback_event("registry.managedSurface.create.end")
factory_config_begin = registry_callback_event("managedSurface.factory.config.begin")
factory_config_end = registry_callback_event("managedSurface.factory.config.end")
factory_view_allocate_begin = registry_callback_event("managedSurface.factory.view.allocate.begin")
factory_view_allocate_end = registry_callback_event("managedSurface.factory.view.allocate.end")
factory_platform_config_begin = registry_callback_event("managedSurface.factory.platformConfig.begin")
factory_platform_config_end = registry_callback_event("managedSurface.factory.platformConfig.end")
factory_native_surface_new_begin = registry_callback_event("managedSurface.factory.nativeSurface.new.begin")
factory_native_surface_new_end = registry_callback_event("managedSurface.factory.nativeSurface.new.end")
factory_lifecycle_bind_begin = registry_callback_event("managedSurface.factory.lifecycleBind.begin")
factory_lifecycle_bind_end = registry_callback_event("managedSurface.factory.lifecycleBind.end")
factory_control_surface_init_begin = registry_callback_event("managedSurface.factory.controlSurface.init.begin")
factory_control_surface_init_end = registry_callback_event("managedSurface.factory.controlSurface.init.end")
factory_initial_state_begin = registry_callback_event("managedSurface.factory.initialState.begin")
factory_initial_state_end = registry_callback_event("managedSurface.factory.initialState.end")
factory_scroll_state_begin = registry_callback_event("managedSurface.factory.scrollState.begin")
factory_scroll_state_end = registry_callback_event("managedSurface.factory.scrollState.end")
factory_managed_init_begin = registry_callback_event("managedSurface.factory.managed.init.begin")
factory_managed_init_end = registry_callback_event("managedSurface.factory.managed.init.end")
factory_display_callback_assign_begin = registry_callback_event(
    "managedSurface.factory.displayCallback.assign.begin"
)
factory_display_callback_assign_end = registry_callback_event(
    "managedSurface.factory.displayCallback.assign.end"
)
registry_managed_register_begin = registry_callback_event("registry.managedSurface.register.begin")
registry_managed_register_end = registry_callback_event("registry.managedSurface.register.end")
registry_stage_presentation_begin = registry_callback_event("registry.stagePresentation.begin")
registry_stage_presentation_end = registry_callback_event("registry.stagePresentation.end")
registry_insert_parent_begin = registry_callback_event("registry.insertSplit.parentLookup.begin")
registry_insert_parent_end = registry_callback_event("registry.insertSplit.parentLookup.end")
registry_insert_assign_begin = registry_callback_event("registry.insertSplit.assign.begin")
registry_insert_assign_end = registry_callback_event("registry.insertSplit.assign.end")
registry_tree_decode_begin = registry_callback_event("registry.createSurfaceTree.decode.begin")
registry_tree_decode_end = registry_callback_event("registry.createSurfaceTree.decode.end")
registry_tree_leaves_begin = registry_callback_event("registry.createSurfaceTree.leaves.begin")
registry_tree_leaves_end = registry_callback_event("registry.createSurfaceTree.leaves.end")
registry_tree_build_begin = registry_callback_event("registry.createSurfaceTree.build.begin")
registry_tree_build_end = registry_callback_event("registry.createSurfaceTree.build.end")
registry_tree_install_begin = registry_callback_event("registry.createSurfaceTree.install.begin")
registry_tree_install_end = registry_callback_event("registry.createSurfaceTree.install.end")
registry_tree_handle_write_begin = registry_callback_event("registry.createSurfaceTree.handleWrite.begin")
registry_tree_handle_write_end = registry_callback_event("registry.createSurfaceTree.handleWrite.end")


model_revision_published = after_topology(exact("model.surfaceRegistryRevision.published"))
update_ui_view_begin = after_topology(exact("ui.updateUIView.begin"))
tree_update_begin = after_topology(exact("ui.tree.update.begin"))
tree_sync_begin = after_topology(exact("ui.tree.sync.begin"))
tree_sync_end = after_topology(exact("ui.tree.sync.end"))
tree_update_end = after_topology(exact("ui.tree.update.end"))
layout_visible_begin = after_topology(exact("ui.tree.layoutVisible.begin"))
managed_update_display_begin = after_topology(exact("managed.updateDisplay.begin"))
managed_update_display_applied = after_topology(exact("managed.updateDisplay.applied"))
managed_update_display_end = after_topology(exact("managed.updateDisplay.end"))
display_rendered = after_topology(exact("ui.displayUpdate.rendered"))
record_presentation_begin = after_topology(exact("ui.recordSurfacePresentation.begin"))
view_presented = after_topology(exact("ui.viewPresentation.ready"))
runtime_presentation_ready = after_topology(exact("registry.runtimePresentation.ready"))


def overlay_update_begin(instance: FlowInstance) -> FlowEvent | None:
    start = tree_update_begin(instance)
    end = tree_sync_begin(instance)
    if start is None or end is None:
        return None
    return first_event_between(
        instance,
        start,
        end,
        exact("ui.presentationOverlay.update.begin"),
    )


def overlay_update_end(instance: FlowInstance) -> FlowEvent | None:
    start = overlay_update_begin(instance)
    end = tree_sync_begin(instance)
    if start is None or end is None:
        return None
    return first_event_between(
        instance,
        start,
        end,
        exact("ui.presentationOverlay.update.end"),
    )


def overlay_clear_begin(instance: FlowInstance) -> FlowEvent | None:
    start = overlay_update_begin(instance)
    end = tree_sync_begin(instance)
    if start is None or end is None:
        return None
    return first_event_between(
        instance,
        start,
        end,
        exact("ui.presentationOverlay.clear.begin"),
    )


def overlay_clear_end(instance: FlowInstance) -> FlowEvent | None:
    start = overlay_clear_begin(instance)
    end = tree_sync_begin(instance)
    if start is None or end is None:
        return None
    return first_event_between(
        instance,
        start,
        end,
        exact("ui.presentationOverlay.clear.end"),
    )


def overlay_snapshot_begin(instance: FlowInstance) -> FlowEvent | None:
    start = overlay_update_begin(instance)
    end = tree_sync_begin(instance)
    if start is None or end is None:
        return None
    return first_event_between(
        instance,
        start,
        end,
        exact("ui.presentationOverlay.snapshot.begin"),
    )


def overlay_snapshot_end(instance: FlowInstance) -> FlowEvent | None:
    start = overlay_snapshot_begin(instance)
    end = tree_sync_begin(instance)
    if start is None or end is None:
        return None
    return first_event_between(
        instance,
        start,
        end,
        exact("ui.presentationOverlay.snapshot.end"),
    )


def overlay_hold_begin(instance: FlowInstance) -> FlowEvent | None:
    start = overlay_update_begin(instance)
    end = tree_sync_begin(instance)
    if start is None or end is None:
        return None
    return first_event_between(
        instance,
        start,
        end,
        exact("ui.presentationOverlay.hold.begin"),
    )


def overlay_hold_end(instance: FlowInstance) -> FlowEvent | None:
    start = overlay_hold_begin(instance)
    end = tree_sync_begin(instance)
    if start is None or end is None:
        return None
    return first_event_between(
        instance,
        start,
        end,
        exact("ui.presentationOverlay.hold.end"),
    )


def overlay_add_snapshot_end(instance: FlowInstance) -> FlowEvent | None:
    start = overlay_snapshot_end(instance)
    end = tree_sync_begin(instance)
    if start is None or end is None:
        return None
    return first_event_between(
        instance,
        start,
        end,
        exact("ui.presentationOverlay.addSnapshot.end"),
    )


SEGMENTS = [
    Segment(
        "send_end->ssh_channel_read",
        lambda flow: first_event(flow, exact("host.write.send.end")),
        lambda flow: first_event(flow, prefix("tmux.signal.ssh.channelRead.")),
    ),
    Segment(
        "ssh_channel_read->host_pump_receive",
        lambda flow: first_event(flow, prefix("tmux.signal.ssh.channelRead.")),
        lambda flow: first_event(flow, prefix("tmux.signal.host.pump.receive.")),
    ),
    Segment(
        "host_pump_receive->sequencer_enqueue",
        lambda flow: first_event(flow, prefix("tmux.signal.host.pump.receive.")),
        lambda flow: first_event(flow, prefix("tmux.signal.sequencer.enqueue.")),
    ),
    Segment(
        "sequencer_enqueue->sequencer_drain",
        lambda flow: first_event(flow, prefix("tmux.signal.sequencer.enqueue.")),
        lambda flow: first_event(flow, prefix("tmux.signal.sequencer.drain.")),
    ),
    Segment(
        "sequencer_drain->tmux_response",
        lambda flow: first_event(flow, prefix("tmux.signal.sequencer.drain.")),
        lambda flow: first_event(flow, prefix("tmux.response.")),
    ),
    Segment(
        "tmux_response->processOutput_end",
        lambda flow: first_event(flow, prefix("tmux.response.")),
        process_output_end,
    ),
    *query_roundtrip_segments(),
    Segment(
        "tmux_response->runtime_wakeup_entry",
        tmux_response,
        runtime_wakeup_entry,
    ),
    Segment(
        "runtime_wakeup_entry->processOutput_end",
        runtime_wakeup_entry,
        process_output_end,
    ),
    Segment(
        "processOutput_end->runtime_callback_entry",
        process_output_end,
        runtime_callback_entry,
    ),
    Segment(
        "processOutput_end->runtime_wakeup_entry",
        process_output_end,
        runtime_wakeup_entry,
    ),
    Segment(
        "runtime_wakeup_entry->wakeup_mainActor_schedule",
        runtime_wakeup_entry,
        runtime_wakeup_main_actor_schedule,
    ),
    Segment(
        "wakeup_mainActor_schedule->wakeup_mainActor_begin",
        runtime_wakeup_main_actor_schedule,
        runtime_wakeup_main_actor_begin,
    ),
    Segment(
        "wakeup_mainActor_begin->app_tick_begin",
        runtime_wakeup_main_actor_begin,
        runtime_wakeup_app_tick_begin,
    ),
    Segment(
        "app_tick_begin->runtime_callback_entry",
        runtime_wakeup_app_tick_begin,
        runtime_callback_entry,
    ),
    Segment(
        "app_tick_begin->app_tick_end",
        runtime_wakeup_app_tick_begin,
        runtime_wakeup_app_tick_end,
    ),
    Segment(
        "runtime_callback_entry->mainActor_schedule",
        runtime_callback_entry,
        runtime_callback_main_actor_schedule,
    ),
    Segment(
        "mainActor_schedule->mainActor_begin",
        runtime_callback_main_actor_schedule,
        runtime_callback_main_actor_begin,
    ),
    Segment(
        "runtime_callback_entry->mainActor_begin",
        runtime_callback_entry,
        runtime_callback_main_actor_begin,
    ),
    Segment(
        "mainActor_begin->registry_callback_begin",
        runtime_callback_main_actor_begin,
        registry_callback_begin,
    ),
    Segment(
        "runtime_callback_entry->registry_callback_begin",
        runtime_callback_entry,
        registry_callback_begin,
    ),
    Segment(
        "processOutput_end->registry_callback_begin",
        process_output_end,
        registry_callback_begin,
    ),
    Segment(
        "registry_callback_begin->topology_installed",
        registry_callback_begin,
        lambda flow: first_event(flow, exact("registry.topology.installed")),
    ),
    Segment(
        "registry_callback_begin->debug_update_begin",
        registry_callback_begin,
        registry_debug_update_begin,
    ),
    Segment(
        "debug_update_begin->debug_update_end",
        registry_debug_update_begin,
        registry_debug_update_end,
    ),
    Segment(
        "debug_update_end->notify_begin",
        registry_debug_update_end,
        registry_notify_begin,
    ),
    Segment(
        "notify_begin->notify_end",
        registry_notify_begin,
        registry_notify_end,
    ),
    Segment(
        "registry_callback_begin->managed_create_begin",
        registry_callback_begin,
        registry_managed_create_begin,
    ),
    Segment(
        "managed_create_begin->managed_create_end",
        registry_managed_create_begin,
        registry_managed_create_end,
    ),
    Segment(
        "managed_create_begin->factory_config_begin",
        registry_managed_create_begin,
        factory_config_begin,
    ),
    Segment(
        "factory_config_begin->factory_config_end",
        factory_config_begin,
        factory_config_end,
    ),
    Segment(
        "factory_config_end->factory_view_allocate_begin",
        factory_config_end,
        factory_view_allocate_begin,
    ),
    Segment(
        "factory_view_allocate_begin->factory_view_allocate_end",
        factory_view_allocate_begin,
        factory_view_allocate_end,
    ),
    Segment(
        "factory_view_allocate_end->factory_platform_config_begin",
        factory_view_allocate_end,
        factory_platform_config_begin,
    ),
    Segment(
        "factory_platform_config_begin->factory_platform_config_end",
        factory_platform_config_begin,
        factory_platform_config_end,
    ),
    Segment(
        "factory_platform_config_end->factory_native_surface_new_begin",
        factory_platform_config_end,
        factory_native_surface_new_begin,
    ),
    Segment(
        "factory_native_surface_new_begin->factory_native_surface_new_end",
        factory_native_surface_new_begin,
        factory_native_surface_new_end,
    ),
    Segment(
        "factory_native_surface_new_end->factory_lifecycle_bind_begin",
        factory_native_surface_new_end,
        factory_lifecycle_bind_begin,
    ),
    Segment(
        "factory_lifecycle_bind_begin->factory_lifecycle_bind_end",
        factory_lifecycle_bind_begin,
        factory_lifecycle_bind_end,
    ),
    Segment(
        "factory_lifecycle_bind_end->factory_control_surface_init_begin",
        factory_lifecycle_bind_end,
        factory_control_surface_init_begin,
    ),
    Segment(
        "factory_control_surface_init_begin->factory_control_surface_init_end",
        factory_control_surface_init_begin,
        factory_control_surface_init_end,
    ),
    Segment(
        "factory_control_surface_init_end->factory_initial_state_begin",
        factory_control_surface_init_end,
        factory_initial_state_begin,
    ),
    Segment(
        "factory_initial_state_begin->factory_initial_state_end",
        factory_initial_state_begin,
        factory_initial_state_end,
    ),
    Segment(
        "factory_initial_state_end->factory_scroll_state_begin",
        factory_initial_state_end,
        factory_scroll_state_begin,
    ),
    Segment(
        "factory_scroll_state_begin->factory_scroll_state_end",
        factory_scroll_state_begin,
        factory_scroll_state_end,
    ),
    Segment(
        "factory_scroll_state_end->factory_managed_init_begin",
        factory_scroll_state_end,
        factory_managed_init_begin,
    ),
    Segment(
        "factory_managed_init_begin->factory_managed_init_end",
        factory_managed_init_begin,
        factory_managed_init_end,
    ),
    Segment(
        "factory_managed_init_end->factory_display_callback_assign_begin",
        factory_managed_init_end,
        factory_display_callback_assign_begin,
    ),
    Segment(
        "factory_display_callback_assign_begin->factory_display_callback_assign_end",
        factory_display_callback_assign_begin,
        factory_display_callback_assign_end,
    ),
    Segment(
        "factory_display_callback_assign_end->managed_create_end",
        factory_display_callback_assign_end,
        registry_managed_create_end,
    ),
    Segment(
        "managed_create_end->insert_parent_lookup_begin",
        registry_managed_create_end,
        registry_insert_parent_begin,
    ),
    Segment(
        "insert_parent_lookup_begin->insert_parent_lookup_end",
        registry_insert_parent_begin,
        registry_insert_parent_end,
    ),
    Segment(
        "insert_parent_lookup_end->managed_register_begin",
        registry_insert_parent_end,
        registry_managed_register_begin,
    ),
    Segment(
        "managed_create_end->managed_register_begin",
        registry_managed_create_end,
        registry_managed_register_begin,
    ),
    Segment(
        "managed_register_begin->managed_register_end",
        registry_managed_register_begin,
        registry_managed_register_end,
    ),
    Segment(
        "managed_register_end->insert_assign_begin",
        registry_managed_register_end,
        registry_insert_assign_begin,
    ),
    Segment(
        "insert_assign_begin->insert_assign_end",
        registry_insert_assign_begin,
        registry_insert_assign_end,
    ),
    Segment(
        "insert_assign_end->stage_presentation_begin",
        registry_insert_assign_end,
        registry_stage_presentation_begin,
    ),
    Segment(
        "managed_register_end->stage_presentation_begin",
        registry_managed_register_end,
        registry_stage_presentation_begin,
    ),
    Segment(
        "stage_presentation_begin->stage_presentation_end",
        registry_stage_presentation_begin,
        registry_stage_presentation_end,
    ),
    Segment(
        "stage_presentation_end->topology_installed",
        registry_stage_presentation_end,
        topology_installed,
    ),
    Segment(
        "tree_decode_begin->tree_decode_end",
        registry_tree_decode_begin,
        registry_tree_decode_end,
    ),
    Segment(
        "tree_decode_end->tree_leaves_begin",
        registry_tree_decode_end,
        registry_tree_leaves_begin,
    ),
    Segment(
        "tree_leaves_begin->tree_leaves_end",
        registry_tree_leaves_begin,
        registry_tree_leaves_end,
    ),
    Segment(
        "tree_leaves_end->tree_build_begin",
        registry_tree_leaves_end,
        registry_tree_build_begin,
    ),
    Segment(
        "tree_build_begin->tree_build_end",
        registry_tree_build_begin,
        registry_tree_build_end,
    ),
    Segment(
        "tree_build_end->tree_install_begin",
        registry_tree_build_end,
        registry_tree_install_begin,
    ),
    Segment(
        "tree_install_begin->tree_install_end",
        registry_tree_install_begin,
        registry_tree_install_end,
    ),
    Segment(
        "tree_install_end->tree_handle_write_begin",
        registry_tree_install_end,
        registry_tree_handle_write_begin,
    ),
    Segment(
        "tree_handle_write_begin->tree_handle_write_end",
        registry_tree_handle_write_begin,
        registry_tree_handle_write_end,
    ),
    Segment(
        "tree_handle_write_end->topology_installed",
        registry_tree_handle_write_end,
        topology_installed,
    ),
    Segment(
        "topology_installed->model_revision_published",
        topology_installed,
        model_revision_published,
    ),
    Segment(
        "model_revision_published->updateUIView_begin",
        model_revision_published,
        after_event(model_revision_published, exact("ui.updateUIView.begin")),
    ),
    Segment(
        "topology_installed->updateUIView_begin",
        topology_installed,
        update_ui_view_begin,
    ),
    Segment(
        "updateUIView_begin->tree_update_begin",
        update_ui_view_begin,
        after_event(update_ui_view_begin, exact("ui.tree.update.begin")),
    ),
    Segment(
        "tree_update_begin->tree_sync_begin",
        tree_update_begin,
        after_event(tree_update_begin, exact("ui.tree.sync.begin")),
    ),
    Segment(
        "tree_update_begin->overlay_update_begin",
        tree_update_begin,
        overlay_update_begin,
    ),
    Segment(
        "overlay_update_begin->snapshot_begin",
        overlay_update_begin,
        overlay_snapshot_begin,
    ),
    Segment(
        "snapshot_begin->snapshot_end",
        overlay_snapshot_begin,
        overlay_snapshot_end,
    ),
    Segment(
        "snapshot_end->addSnapshot_end",
        overlay_snapshot_end,
        overlay_add_snapshot_end,
    ),
    Segment(
        "addSnapshot_end->tree_sync_begin",
        overlay_add_snapshot_end,
        tree_sync_begin,
    ),
    Segment(
        "overlay_update_begin->hold_begin",
        overlay_update_begin,
        overlay_hold_begin,
    ),
    Segment(
        "hold_begin->hold_end",
        overlay_hold_begin,
        overlay_hold_end,
    ),
    Segment(
        "hold_end->tree_sync_begin",
        overlay_hold_end,
        tree_sync_begin,
    ),
    Segment(
        "overlay_update_begin->overlay_update_end",
        overlay_update_begin,
        overlay_update_end,
    ),
    Segment(
        "overlay_update_end->tree_sync_begin",
        overlay_update_end,
        tree_sync_begin,
    ),
    Segment(
        "overlay_clear_begin->overlay_clear_end",
        overlay_clear_begin,
        overlay_clear_end,
    ),
    Segment(
        "tree_sync_begin->tree_sync_end",
        tree_sync_begin,
        after_event(tree_sync_begin, exact("ui.tree.sync.end")),
    ),
    Segment(
        "tree_update_begin->tree_sync_end",
        tree_update_begin,
        tree_sync_end,
    ),
    Segment(
        "tree_sync_end->tree_update_end",
        tree_sync_end,
        after_event(tree_sync_end, exact("ui.tree.update.end")),
    ),
    Segment(
        "tree_sync_end->layout_visible_begin",
        tree_sync_end,
        after_event(tree_sync_end, exact("ui.tree.layoutVisible.begin")),
    ),
    Segment(
        "tree_update_end->layout_visible_begin",
        tree_update_end,
        after_event(tree_update_end, exact("ui.tree.layoutVisible.begin")),
    ),
    Segment(
        "layout_visible_begin->managed_update_display_begin",
        layout_visible_begin,
        after_event(layout_visible_begin, exact("managed.updateDisplay.begin")),
    ),
    Segment(
        "managed_update_display_begin->managed_update_display_applied",
        managed_update_display_begin,
        after_event(managed_update_display_begin, exact("managed.updateDisplay.applied")),
    ),
    Segment(
        "managed_update_display_applied->display_rendered",
        managed_update_display_applied,
        after_event(managed_update_display_applied, exact("ui.displayUpdate.rendered")),
    ),
    Segment(
        "display_rendered->managed_update_display_end",
        display_rendered,
        after_event(display_rendered, exact("managed.updateDisplay.end")),
    ),
    Segment(
        "managed_update_display_end->record_presentation_begin",
        managed_update_display_end,
        after_event(managed_update_display_end, exact("ui.recordSurfacePresentation.begin")),
    ),
    Segment(
        "record_presentation_begin->view_presented",
        record_presentation_begin,
        after_event(record_presentation_begin, exact("ui.viewPresentation.ready")),
    ),
    Segment(
        "topology_installed->display_rendered",
        topology_installed,
        display_rendered,
    ),
    Segment(
        "display_rendered->view_presented",
        display_rendered,
        view_presented,
    ),
    Segment(
        "view_presented->runtime_presentation_ready",
        view_presented,
        runtime_presentation_ready,
    ),
    Segment(
        "topology_installed->view_presented",
        topology_installed,
        view_presented,
    ),
    Segment(
        "topology_installed->runtime_presentation_ready",
        topology_installed,
        runtime_presentation_ready,
    ),
    Segment(
        "last_presentation_fact->interactive_ready",
        latest_after_topology(any_of("ui.viewPresentation.ready", "registry.runtimePresentation.ready")),
        lambda flow: first_event(flow, exact("interactive.ready")),
    ),
    Segment(
        "runtime_presentation_ready->interactive_ready",
        runtime_presentation_ready,
        lambda flow: first_event(flow, exact("interactive.ready")),
    ),
    Segment(
        "topology_installed->interactive_ready",
        lambda flow: first_event(flow, exact("registry.topology.installed")),
        lambda flow: first_event(flow, exact("interactive.ready")),
    ),
    Segment(
        "send_end->interactive_ready",
        lambda flow: first_event(flow, exact("host.write.send.end")),
        lambda flow: first_event(flow, exact("interactive.ready")),
    ),
]


def query_count_metrics() -> list[CountMetric]:
    metrics: list[CountMetric] = []
    for kind in QUERY_KINDS:
        metrics.extend(
            [
                CountMetric(
                    f"send_end->interactive_ready tmux.query.{kind}.send count",
                    lambda flow: first_event(flow, exact("host.write.send.end")),
                    lambda flow: first_event(flow, exact("interactive.ready")),
                    exact(f"tmux.query.{kind}.send"),
                ),
                CountMetric(
                    f"send_end->interactive_ready tmux.query.{kind}.response_processed count",
                    lambda flow: first_event(flow, exact("host.write.send.end")),
                    lambda flow: first_event(flow, exact("interactive.ready")),
                    exact(f"tmux.query.{kind}.response.processed"),
                ),
            ]
        )
    return metrics


COUNT_METRICS = [
    *query_count_metrics(),
    CountMetric(
        "registry_callback_begin->topology_installed registry.notifyChanged.begin count",
        registry_callback_begin,
        topology_installed,
        exact("registry.notifyChanged.begin"),
    ),
    CountMetric(
        "topology_installed->interactive_ready registry.notifyChanged.begin count",
        topology_installed,
        lambda flow: first_event(flow, exact("interactive.ready")),
        exact("registry.notifyChanged.begin"),
    ),
    CountMetric(
        "topology_installed->interactive_ready model.surfaceRegistryRevision.published count",
        topology_installed,
        lambda flow: first_event(flow, exact("interactive.ready")),
        exact("model.surfaceRegistryRevision.published"),
    ),
]


def parse_events(paths: Iterable[Path]) -> list[FlowEvent]:
    events: dict[tuple[int, str, str, tuple[tuple[str, str], ...]], FlowEvent] = {}
    for path in paths:
        for line in path.read_text(errors="replace").splitlines():
            match = FLOW_RE.search(line)
            if match is None:
                continue

            event = flow_event(match, source=str(path))
            events[(event.timestamp, event.flow, event.event, event.fields)] = event

    return sorted(events.values(), key=lambda event: event.timestamp)


def flow_event(match: re.Match[str], source: str) -> FlowEvent:
    return FlowEvent(
        timestamp=int(match.group("timestamp")),
        flow=match.group("flow"),
        event=match.group("event"),
        since_ms=float(match.group("since")),
        source=source,
        fields=parse_trace_fields(match.group("fields") or ""),
    )


def parse_trace_fields(raw: str) -> tuple[tuple[str, str], ...]:
    fields: list[tuple[str, str]] = []
    for token in raw.strip().split():
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        if key:
            fields.append((key, value))
    return tuple(sorted(fields))


def parse_native_surface_init_events(paths: Iterable[Path]) -> list[NativeSurfaceInitEvent]:
    events: list[NativeSurfaceInitEvent] = []
    for path in paths:
        for line in path.read_text(errors="replace").splitlines():
            match = NATIVE_SURFACE_INIT_RE.search(line)
            if match is None:
                continue

            events.append(native_surface_init_event(match, source=str(path)))

    return sorted(
        dedupe_native_surface_events(fill_native_surface_context(events)),
        key=lambda event: (event.timestamp, event.source, event.sequence, event.phase),
    )


def native_surface_init_event(
    match: re.Match[str],
    source: str,
) -> NativeSurfaceInitEvent:
    return NativeSurfaceInitEvent(
        timestamp=int(match.group("timestamp")),
        sequence=int(match.group("sequence")),
        phase=match.group("phase"),
        duration_ms=int(match.group("duration_ns")) / 1_000_000,
        context=match.group("context") or "unknown",
        backing=match.group("backing") or "unknown",
        source=source,
    )


def fill_native_surface_context(
    events: list[NativeSurfaceInitEvent],
) -> list[NativeSurfaceInitEvent]:
    known_contexts: dict[tuple[str, int], tuple[str, str]] = {}
    for event in events:
        if event.context == "unknown" or event.backing == "unknown":
            continue
        known_contexts.setdefault(
            (event.source, event.sequence),
            (event.context, event.backing),
        )

    filled: list[NativeSurfaceInitEvent] = []
    for event in events:
        if event.context != "unknown" and event.backing != "unknown":
            filled.append(event)
            continue

        context, backing = known_contexts.get(
            (event.source, event.sequence),
            (event.context, event.backing),
        )
        filled.append(
            NativeSurfaceInitEvent(
                timestamp=event.timestamp,
                sequence=event.sequence,
                phase=event.phase,
                duration_ms=event.duration_ms,
                context=context,
                backing=backing,
                source=event.source,
            )
        )

    return filled


def dedupe_native_surface_events(
    events: list[NativeSurfaceInitEvent],
) -> list[NativeSurfaceInitEvent]:
    deduped: dict[tuple[int, int, str, float, str, str], NativeSurfaceInitEvent] = {}
    for event in events:
        key = (
            event.timestamp,
            event.sequence,
            event.phase,
            event.duration_ms,
            event.context,
            event.backing,
        )
        deduped.setdefault(key, event)
    return list(deduped.values())


def group_flow_instances(events: Iterable[FlowEvent]) -> list[FlowInstance]:
    start_events = {
        "tmux.newWindow": "ui.tap.newWindow",
        "tmux.splitPane": "ui.tap.splitPane",
    }
    active: dict[str, FlowInstance] = {}
    completed: list[FlowInstance] = []

    for event in events:
        start_event = start_events.get(event.flow)
        if start_event is not None and event.event == start_event:
            active[event.flow] = FlowInstance(
                flow=event.flow,
                started_at=event.timestamp,
                events=[],
            )

        instance = active.get(event.flow)
        if instance is None:
            late_instance = completed_flow_instance_for(event, completed)
            if late_instance is not None:
                late_instance.events.append(event)
            continue

        if is_query_event(event) and not event_belongs_to_instance(event, instance):
            late_instance = completed_flow_instance_for(event, completed)
            if late_instance is not None:
                late_instance.events.append(event)
                continue

        instance.events.append(event)
        if event.event == "interactive.ready":
            completed.append(instance)
            del active[event.flow]

    return completed


def is_query_event(event: FlowEvent) -> bool:
    return event.event.startswith("tmux.query.")


def completed_flow_instance_for(
    event: FlowEvent,
    completed: list[FlowInstance],
) -> FlowInstance | None:
    if not is_query_event(event):
        return None

    for instance in reversed(completed):
        if instance.flow == event.flow and event_belongs_to_instance(event, instance):
            return instance
    return None


def event_belongs_to_instance(event: FlowEvent, instance: FlowInstance) -> bool:
    estimated_started_at = event.timestamp - int(round(event.since_ms * 1_000_000))
    return abs(estimated_started_at - instance.started_at) <= 1_000_000


def percentile(values: list[float], percentile_value: float) -> float:
    ordered = sorted(values)
    if not ordered:
        raise ValueError("percentile requires at least one value")

    position = (len(ordered) - 1) * percentile_value
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    fraction = position - lower
    return ordered[lower] * (1 - fraction) + ordered[upper] * fraction


def segment_duration_ms(start: FlowEvent, end: FlowEvent) -> float:
    return (end.timestamp - start.timestamp) / 1_000_000


def count_events_between(
    instance: FlowInstance,
    start: FlowEvent,
    end: FlowEvent,
    predicate: Callable[[str], bool],
) -> int:
    return sum(
        1
        for event in instance.events
        if start.timestamp <= event.timestamp <= end.timestamp
        and predicate(event.event)
    )


NATIVE_SURFACE_PHASE_ORDER = [
    "native.surfaceNew.capi",
    "native.surfaceNew.wrapper",
    "native.app.newSurface.alloc",
    "native.app.newSurface.surfaceInit",
    "native.embeddedSurface.init.total",
    "native.embeddedSurface.fields",
    "native.embeddedSurface.appAdd",
    "native.embeddedSurface.config",
    "native.embeddedSurface.coreSurfaceInit",
    "native.coreSurface.init.total",
    "native.coreSurface.conditionalConfig",
    "native.coreSurface.derivedConfig",
    "native.coreSurface.renderer.surfaceInit",
    "native.coreSurface.contentScale",
    "native.coreSurface.fontGridRef",
    "native.coreSurface.size",
    "native.coreSurface.renderer.init",
    "native.coreSurface.rendererState",
    "native.coreSurface.rendererThread.init",
    "native.coreSurface.ioThread.init",
    "native.coreSurface.assignState",
    "native.coreSurface.termio.init",
    "native.coreSurface.appActions",
    "native.coreSurface.resize",
    "native.coreSurface.renderer.finalize",
    "native.coreSurface.rendererThread.spawn",
    "native.coreSurface.ioThread.spawn",
]


def native_phase_order(phases: Iterable[str]) -> list[str]:
    phase_set = set(phases)
    ordered = [phase for phase in NATIVE_SURFACE_PHASE_ORDER if phase in phase_set]
    extras = sorted(phase_set - set(NATIVE_SURFACE_PHASE_ORDER))
    return ordered + extras


def report_native_surface_init(events: list[NativeSurfaceInitEvent]) -> str:
    if not events:
        return "native_surface_init_traces=0"

    lines = [f"native_surface_init_traces={len(events)}"]
    groups: list[tuple[str, list[NativeSurfaceInitEvent]]] = [("all", events)]
    grouped_keys = sorted({(event.context, event.backing) for event in events})
    groups.extend(
        (
            f"context={context} backing={backing}",
            [
                event
                for event in events
                if event.context == context and event.backing == backing
            ],
        )
        for context, backing in grouped_keys
    )

    for label, group_events in groups:
        surface_count = len({(event.source, event.sequence) for event in group_events})
        lines.append(
            f"[native.surfaceInit {label}] surfaces={surface_count} samples={len(group_events)}"
        )
        for phase in native_phase_order(event.phase for event in group_events):
            values = [
                event.duration_ms
                for event in group_events
                if event.phase == phase
            ]
            if not values:
                continue
            lines.append(
                f"{phase}: "
                f"n={len(values)} "
                f"p50_ms={statistics.median(values):.3f} "
                f"p95_ms={percentile(values, 0.95):.3f} "
                f"max_ms={max(values):.3f}"
            )

    return "\n".join(lines)


def report(instances: list[FlowInstance]) -> str:
    lines = [f"distinct_action_flows={len(instances)}"]
    for flow in ("tmux.newWindow", "tmux.splitPane"):
        flow_instances = [instance for instance in instances if instance.flow == flow]
        lines.append(f"[{flow}] n={len(flow_instances)}")
        for segment in SEGMENTS:
            values: list[float] = []
            missing = 0
            out_of_order = 0
            for instance in flow_instances:
                event_pairs = (
                    segment.pairs(instance)
                    if segment.pairs is not None
                    else [(segment.start(instance), segment.end(instance))]
                )
                for start, end in event_pairs:
                    if start is None or end is None:
                        missing += 1
                        continue
                    if end.timestamp < start.timestamp:
                        out_of_order += 1
                        continue
                    values.append(segment_duration_ms(start, end))

            if values:
                line = (
                    f"{segment.name}: "
                    f"n={len(values)} "
                    f"p50_ms={statistics.median(values):.3f} "
                    f"p95_ms={percentile(values, 0.95):.3f} "
                    f"max_ms={max(values):.3f}"
                )
                if missing:
                    line += f" missing={missing}"
                if out_of_order:
                    line += f" out_of_order={out_of_order}"
                lines.append(line)
            else:
                lines.append(
                    f"{segment.name}: n=0 missing={missing} out_of_order={out_of_order}"
                )

        for metric in COUNT_METRICS:
            counts: list[int] = []
            missing = 0
            out_of_order = 0
            for instance in flow_instances:
                start = metric.start(instance)
                end = metric.end(instance)
                if start is None or end is None:
                    missing += 1
                    continue
                if end.timestamp < start.timestamp:
                    out_of_order += 1
                    continue
                counts.append(count_events_between(instance, start, end, metric.predicate))

            if counts:
                line = (
                    f"{metric.name}: "
                    f"n={len(counts)} "
                    f"p50_count={statistics.median(counts):.1f} "
                    f"p95_count={percentile([float(count) for count in counts], 0.95):.1f} "
                    f"max_count={max(counts)}"
                )
                if missing:
                    line += f" missing={missing}"
                if out_of_order:
                    line += f" out_of_order={out_of_order}"
                lines.append(line)
            else:
                lines.append(
                    f"{metric.name}: n=0 missing={missing} out_of_order={out_of_order}"
                )

    return "\n".join(lines)


def run_self_test() -> None:
    sample = """
Remux flow t=1000000 flow=tmux.newWindow event=ui.tap.newWindow since_ms=0.000
Remux flow t=2000000 flow=tmux.newWindow event=host.write.send.end since_ms=1.000
Remux flow t=2100000 flow=tmux.newWindow event=tmux.query.list_windows.send since_ms=1.100 command=list_windows kind=list_windows sequence=10
Remux flow t=3000000 flow=tmux.newWindow event=tmux.signal.ssh.channelRead.window-add since_ms=2.000
Remux flow t=4000000 flow=tmux.newWindow event=tmux.signal.host.pump.receive.window-add since_ms=3.000
Remux flow t=5000000 flow=tmux.newWindow event=tmux.signal.sequencer.enqueue.window-add since_ms=4.000
Remux flow t=7000000 flow=tmux.newWindow event=tmux.signal.sequencer.drain.window-add since_ms=6.000
Remux flow t=7600000 flow=tmux.newWindow event=tmux.query.list_windows.response.receive since_ms=6.600 kind=list_windows outcome=end sequence=10
Remux flow t=8000000 flow=tmux.newWindow event=tmux.response.window-add since_ms=7.000
Remux flow t=8300000 flow=tmux.newWindow event=runtime.callback.createSurfaceTree.entry since_ms=7.300
Remux flow t=8400000 flow=tmux.newWindow event=runtime.callback.createSurfaceTree.mainActor.begin since_ms=7.400
Remux flow t=8450000 flow=tmux.newWindow event=registry.createSurfaceTree.begin since_ms=7.450
Remux flow t=8500000 flow=tmux.newWindow event=tmux.signal.host.pump.processOutput.end.window-add since_ms=7.500
Remux flow t=8510000 flow=tmux.newWindow event=tmux.query.list_windows.response.processed since_ms=7.510 accepted=true kind=list_windows outcome=end sequence=10
Remux flow t=8550000 flow=tmux.newWindow event=runtime.wakeup.entry since_ms=7.550
Remux flow t=8600000 flow=tmux.newWindow event=runtime.wakeup.mainActor.schedule since_ms=7.600
Remux flow t=8700000 flow=tmux.newWindow event=runtime.wakeup.mainActor.begin since_ms=7.700
Remux flow t=8750000 flow=tmux.newWindow event=runtime.wakeup.appTick.begin since_ms=7.750
Remux flow t=8900000 flow=tmux.newWindow event=runtime.callback.createSurfaceTree.entry since_ms=7.900
Remux flow t=8950000 flow=tmux.newWindow event=runtime.wakeup.appTick.end since_ms=7.950
Remux flow t=9000000 flow=tmux.newWindow event=runtime.callback.createSurfaceTree.mainActor.schedule since_ms=8.000
Remux flow t=9200000 flow=tmux.newWindow event=runtime.callback.createSurfaceTree.mainActor.begin since_ms=8.200
Remux flow t=9300000 flow=tmux.newWindow event=registry.createSurfaceTree.begin since_ms=8.300
Remux flow t=9400000 flow=tmux.newWindow event=registry.createSurfaceTree.decode.begin since_ms=8.400
Remux flow t=9450000 flow=tmux.newWindow event=registry.createSurfaceTree.decode.end since_ms=8.450
Remux flow t=9500000 flow=tmux.newWindow event=registry.createSurfaceTree.leaves.begin since_ms=8.500
Remux flow t=9800000 flow=tmux.newWindow event=registry.createSurfaceTree.leaves.end since_ms=8.800
Remux flow t=9900000 flow=tmux.newWindow event=registry.createSurfaceTree.build.begin since_ms=8.900
Remux flow t=9950000 flow=tmux.newWindow event=registry.createSurfaceTree.build.end since_ms=8.950
Remux flow t=10000000 flow=tmux.newWindow event=registry.createSurfaceTree.install.begin since_ms=9.000
Remux flow t=10500000 flow=tmux.newWindow event=registry.createSurfaceTree.install.end since_ms=9.500
Remux flow t=11000000 flow=tmux.newWindow event=registry.createSurfaceTree.handleWrite.begin since_ms=10.000
Remux flow t=11200000 flow=tmux.newWindow event=registry.createSurfaceTree.handleWrite.end since_ms=10.200
Remux flow t=12000000 flow=tmux.newWindow event=registry.topology.installed since_ms=11.000
Remux flow t=12100000 flow=tmux.newWindow event=model.surfaceRegistryRevision.published since_ms=11.100
Remux flow t=12200000 flow=tmux.newWindow event=ui.updateUIView.begin since_ms=11.200
Remux flow t=12300000 flow=tmux.newWindow event=ui.tree.update.begin since_ms=11.300
Remux flow t=12310000 flow=tmux.newWindow event=ui.presentationOverlay.update.begin since_ms=11.310
Remux flow t=12320000 flow=tmux.newWindow event=ui.presentationOverlay.hold.begin since_ms=11.320
Remux flow t=12370000 flow=tmux.newWindow event=ui.presentationOverlay.hold.end since_ms=11.370
Remux flow t=12390000 flow=tmux.newWindow event=ui.presentationOverlay.update.end since_ms=11.390
Remux flow t=12400000 flow=tmux.newWindow event=ui.tree.sync.begin since_ms=11.400
Remux flow t=12410000 flow=tmux.newWindow event=ui.tree.sync.end since_ms=11.410
Remux flow t=12500000 flow=tmux.newWindow event=ui.tree.layoutVisible.begin since_ms=11.500
Remux flow t=12600000 flow=tmux.newWindow event=managed.updateDisplay.begin since_ms=11.600
Remux flow t=12700000 flow=tmux.newWindow event=managed.updateDisplay.applied since_ms=11.700
Remux flow t=13000000 flow=tmux.newWindow event=ui.displayUpdate.rendered since_ms=12.000
Remux flow t=13100000 flow=tmux.newWindow event=managed.updateDisplay.end since_ms=12.100
Remux flow t=13200000 flow=tmux.newWindow event=ui.recordSurfacePresentation.begin since_ms=12.200
Remux flow t=14000000 flow=tmux.newWindow event=ui.viewPresentation.ready since_ms=13.000
Remux flow t=16000000 flow=tmux.newWindow event=registry.runtimePresentation.ready since_ms=15.000
Remux flow t=16500000 flow=tmux.newWindow event=tmux.query.pane_state.send since_ms=15.500 command=pane_state kind=pane_state sequence=11
Remux flow t=17000000 flow=tmux.newWindow event=interactive.ready since_ms=16.000
Remux flow t=18000000 flow=tmux.newWindow event=tmux.query.pane_state.response.receive since_ms=17.000 kind=pane_state outcome=end sequence=11
Remux flow t=19000000 flow=tmux.newWindow event=tmux.query.pane_state.response.processed since_ms=18.000 accepted=true kind=pane_state outcome=end sequence=11
Remux flow t=20000000 flow=tmux.splitPane event=ui.tap.splitPane since_ms=0.000
Remux flow t=21000000 flow=tmux.splitPane event=host.write.send.end since_ms=1.000
Remux flow t=21500000 flow=tmux.splitPane event=tmux.query.pane_metadata.send since_ms=1.500 command=pane_metadata kind=pane_metadata sequence=20
Remux flow t=21600000 flow=tmux.splitPane event=tmux.query.pane_visible.send since_ms=1.600 command=pane_visible kind=pane_visible sequence=30
Remux flow t=21600000 flow=tmux.splitPane event=tmux.query.pane_visible.send since_ms=1.600 command=pane_visible kind=pane_visible sequence=31
Remux flow t=22000000 flow=tmux.splitPane event=tmux.signal.ssh.channelRead.layout-change since_ms=2.000
Remux flow t=23000000 flow=tmux.splitPane event=tmux.signal.host.pump.receive.layout-change since_ms=3.000
Remux flow t=24000000 flow=tmux.splitPane event=tmux.signal.sequencer.enqueue.layout-change since_ms=4.000
Remux flow t=25000000 flow=tmux.splitPane event=tmux.signal.sequencer.drain.layout-change since_ms=5.000
Remux flow t=25500000 flow=tmux.splitPane event=tmux.query.pane_metadata.response.receive since_ms=5.500 kind=pane_metadata outcome=end sequence=20
Remux flow t=25600000 flow=tmux.splitPane event=tmux.query.pane_visible.response.receive since_ms=5.600 kind=pane_visible outcome=end sequence=30
Remux flow t=25700000 flow=tmux.splitPane event=tmux.query.pane_visible.response.receive since_ms=5.700 kind=pane_visible outcome=end sequence=31
Remux flow t=26000000 flow=tmux.splitPane event=tmux.response.layout-change since_ms=6.000
Remux flow t=26450000 flow=tmux.splitPane event=runtime.wakeup.entry since_ms=6.450
Remux flow t=26460000 flow=tmux.splitPane event=runtime.wakeup.mainActor.schedule since_ms=6.460
Remux flow t=26500000 flow=tmux.splitPane event=tmux.signal.host.pump.processOutput.end.layout-change since_ms=6.500
Remux flow t=26510000 flow=tmux.splitPane event=tmux.query.pane_metadata.response.processed since_ms=6.510 accepted=true kind=pane_metadata outcome=end sequence=20
Remux flow t=26520000 flow=tmux.splitPane event=tmux.query.pane_visible.response.processed since_ms=6.520 accepted=true kind=pane_visible outcome=end sequence=30
Remux flow t=26530000 flow=tmux.splitPane event=tmux.query.pane_visible.response.processed since_ms=6.530 accepted=true kind=pane_visible outcome=end sequence=31
Remux flow t=26570000 flow=tmux.splitPane event=runtime.wakeup.mainActor.begin since_ms=6.570
Remux flow t=26580000 flow=tmux.splitPane event=runtime.wakeup.appTick.begin since_ms=6.580
Remux flow t=26600000 flow=tmux.splitPane event=runtime.callback.createSurface.entry since_ms=6.600
Remux flow t=26650000 flow=tmux.splitPane event=runtime.wakeup.appTick.end since_ms=6.650
Remux flow t=26700000 flow=tmux.splitPane event=runtime.callback.createSurface.mainActor.begin since_ms=6.700
Remux flow t=27000000 flow=tmux.splitPane event=registry.createSurface.begin since_ms=7.000
Remux flow t=27050000 flow=tmux.splitPane event=registry.debugSummary.update.begin since_ms=7.050
Remux flow t=27060000 flow=tmux.splitPane event=registry.debugSummary.update.end since_ms=7.060
Remux flow t=27070000 flow=tmux.splitPane event=registry.notifyChanged.begin since_ms=7.070
Remux flow t=27090000 flow=tmux.splitPane event=registry.notifyChanged.end since_ms=7.090
Remux flow t=27100000 flow=tmux.splitPane event=registry.managedSurface.create.begin since_ms=7.100
Remux flow t=27110000 flow=tmux.splitPane event=managedSurface.factory.config.begin since_ms=7.110
Remux flow t=27120000 flow=tmux.splitPane event=managedSurface.factory.config.end since_ms=7.120
Remux flow t=27130000 flow=tmux.splitPane event=managedSurface.factory.view.allocate.begin since_ms=7.130
Remux flow t=27150000 flow=tmux.splitPane event=managedSurface.factory.view.allocate.end since_ms=7.150
Remux flow t=27160000 flow=tmux.splitPane event=managedSurface.factory.platformConfig.begin since_ms=7.160
Remux flow t=27170000 flow=tmux.splitPane event=managedSurface.factory.platformConfig.end since_ms=7.170
Remux flow t=27180000 flow=tmux.splitPane event=managedSurface.factory.nativeSurface.new.begin since_ms=7.180
Ghostty surfaceInit t=27190000 seq=1 phase=native.coreSurface.termio.init duration_ns=2000000 context=split backing=manual
Ghostty surfaceInit t=27195000 seq=1 phase=native.coreSurface.assignState duration_ns=100000
Ghostty surfaceInit t=27200000 seq=1 phase=native.coreSurface.renderer.init duration_ns=500000 context=split backing=manual
Remux flow t=27300000 flow=tmux.splitPane event=managedSurface.factory.nativeSurface.new.end since_ms=7.300
Remux flow t=27310000 flow=tmux.splitPane event=managedSurface.factory.lifecycleBind.begin since_ms=7.310
Remux flow t=27320000 flow=tmux.splitPane event=managedSurface.factory.lifecycleBind.end since_ms=7.320
Remux flow t=27330000 flow=tmux.splitPane event=managedSurface.factory.controlSurface.init.begin since_ms=7.330
Remux flow t=27340000 flow=tmux.splitPane event=managedSurface.factory.controlSurface.init.end since_ms=7.340
Remux flow t=27345000 flow=tmux.splitPane event=managedSurface.factory.initialState.begin since_ms=7.345
Remux flow t=27360000 flow=tmux.splitPane event=managedSurface.factory.initialState.end since_ms=7.360
Remux flow t=27365000 flow=tmux.splitPane event=managedSurface.factory.scrollState.begin since_ms=7.365
Remux flow t=27380000 flow=tmux.splitPane event=managedSurface.factory.scrollState.end since_ms=7.380
Remux flow t=27385000 flow=tmux.splitPane event=managedSurface.factory.managed.init.begin since_ms=7.385
Remux flow t=27390000 flow=tmux.splitPane event=managedSurface.factory.managed.init.end since_ms=7.390
Remux flow t=27392000 flow=tmux.splitPane event=managedSurface.factory.displayCallback.assign.begin since_ms=7.392
Remux flow t=27395000 flow=tmux.splitPane event=managedSurface.factory.displayCallback.assign.end since_ms=7.395
Remux flow t=27400000 flow=tmux.splitPane event=registry.managedSurface.create.end since_ms=7.400
Remux flow t=27450000 flow=tmux.splitPane event=registry.insertSplit.parentLookup.begin since_ms=7.450
Remux flow t=27500000 flow=tmux.splitPane event=registry.insertSplit.parentLookup.end since_ms=7.500
Remux flow t=27600000 flow=tmux.splitPane event=registry.managedSurface.register.begin since_ms=7.600
Remux flow t=27700000 flow=tmux.splitPane event=registry.managedSurface.register.end since_ms=7.700
Remux flow t=27750000 flow=tmux.splitPane event=registry.insertSplit.assign.begin since_ms=7.750
Remux flow t=27800000 flow=tmux.splitPane event=registry.insertSplit.assign.end since_ms=7.800
Remux flow t=27850000 flow=tmux.splitPane event=registry.stagePresentation.begin since_ms=7.850
Remux flow t=27900000 flow=tmux.splitPane event=registry.stagePresentation.end since_ms=7.900
Remux flow t=28000000 flow=tmux.splitPane event=registry.topology.installed since_ms=8.000
Remux flow t=29000000 flow=tmux.splitPane event=registry.runtimePresentation.ready since_ms=9.000
Remux flow t=30000000 flow=tmux.splitPane event=ui.viewPresentation.ready since_ms=10.000
Remux flow t=31000000 flow=tmux.splitPane event=interactive.ready since_ms=11.000
Remux flow t=1000000 flow=tmux.newWindow event=ui.tap.newWindow since_ms=0.000
""".strip()
    events = []
    for line in sample.splitlines():
        match = FLOW_RE.search(line)
        if match is None:
            continue
        events.append(flow_event(match, source="self-test"))

    instances = group_flow_instances(events)
    output = report(instances)
    native_events = []
    for line in sample.splitlines():
        match = NATIVE_SURFACE_INIT_RE.search(line)
        if match is None:
            continue
        native_events.append(native_surface_init_event(match, source="self-test"))
    native_events.append(
        NativeSurfaceInitEvent(
            timestamp=27250000,
            sequence=1,
            phase="native.coreSurface.assignState",
            duration_ms=0.2,
            context="split",
            backing="manual",
            source="second-self-test-log",
        )
    )
    native_events.append(
        NativeSurfaceInitEvent(
            timestamp=27190000,
            sequence=1,
            phase="native.coreSurface.termio.init",
            duration_ms=2.0,
            context="split",
            backing="manual",
            source="duplicate-self-test-log",
        )
    )
    native_events = dedupe_native_surface_events(fill_native_surface_context(native_events))
    native_output = report_native_surface_init(native_events)
    assert "distinct_action_flows=2" in output
    assert "send_end->ssh_channel_read: n=1 p50_ms=1.000" in output
    assert "processOutput_end->runtime_callback_entry: n=1 p50_ms=0.400" in output
    assert "query.list_windows.send->response_receive: n=1 p50_ms=5.500" in output
    assert "query.list_windows.response_receive->response_processed: n=1 p50_ms=0.910" in output
    assert "query.pane_state.send->response_processed: n=1 p50_ms=2.500" in output
    assert "query.pane_metadata.send->response_processed: n=1 p50_ms=5.010" in output
    assert "query.pane_visible.send->response_receive: n=2 p50_ms=4.050" in output
    assert "query.pane_visible.response_receive->response_processed: n=2 p50_ms=0.875" in output
    assert "query.pane_visible.send->response_processed: n=2 p50_ms=4.925" in output
    assert "tmux_response->runtime_wakeup_entry: n=1 p50_ms=0.550" in output
    assert "tmux_response->runtime_wakeup_entry: n=1 p50_ms=0.450" in output
    assert "runtime_wakeup_entry->processOutput_end: n=1 p50_ms=0.050" in output
    assert "processOutput_end->runtime_wakeup_entry: n=1 p50_ms=0.050" in output
    assert (
        "processOutput_end->runtime_wakeup_entry: "
        "n=0 missing=0 out_of_order=1"
    ) in output
    assert (
        "runtime_wakeup_entry->wakeup_mainActor_schedule: "
        "n=1 p50_ms=0.050"
    ) in output
    assert (
        "wakeup_mainActor_schedule->wakeup_mainActor_begin: "
        "n=1 p50_ms=0.100"
    ) in output
    assert "wakeup_mainActor_begin->app_tick_begin: n=1 p50_ms=0.050" in output
    assert "app_tick_begin->runtime_callback_entry: n=1 p50_ms=0.150" in output
    assert "app_tick_begin->app_tick_end: n=1 p50_ms=0.200" in output
    assert "mainActor_schedule->mainActor_begin: n=1 p50_ms=0.200" in output
    assert "runtime_callback_entry->registry_callback_begin: n=1 p50_ms=0.400" in output
    assert "mainActor_begin->registry_callback_begin: n=1 p50_ms=0.100" in output
    assert "processOutput_end->registry_callback_begin: n=1 p50_ms=0.800" in output
    assert "tree_decode_begin->tree_decode_end: n=1 p50_ms=0.050" in output
    assert "tree_leaves_begin->tree_leaves_end: n=1 p50_ms=0.300" in output
    assert "tree_install_begin->tree_install_end: n=1 p50_ms=0.500" in output
    assert "tree_handle_write_end->topology_installed: n=1 p50_ms=0.800" in output
    assert "managed_create_begin->managed_create_end: n=1 p50_ms=0.300" in output
    assert "factory_config_begin->factory_config_end: n=1 p50_ms=0.010" in output
    assert (
        "factory_view_allocate_begin->factory_view_allocate_end: "
        "n=1 p50_ms=0.020"
    ) in output
    assert (
        "factory_native_surface_new_begin->factory_native_surface_new_end: "
        "n=1 p50_ms=0.120"
    ) in output
    assert "factory_initial_state_begin->factory_initial_state_end: n=1 p50_ms=0.015" in output
    assert "factory_scroll_state_begin->factory_scroll_state_end: n=1 p50_ms=0.015" in output
    assert (
        "factory_display_callback_assign_end->managed_create_end: "
        "n=1 p50_ms=0.005"
    ) in output
    assert "insert_parent_lookup_begin->insert_parent_lookup_end: n=1 p50_ms=0.050" in output
    assert "managed_register_begin->managed_register_end: n=1 p50_ms=0.100" in output
    assert "stage_presentation_begin->stage_presentation_end: n=1 p50_ms=0.050" in output
    assert "topology_installed->model_revision_published: n=1 p50_ms=0.100" in output
    assert "tree_update_begin->overlay_update_begin: n=1 p50_ms=0.010" in output
    assert "overlay_update_begin->hold_begin: n=1 p50_ms=0.010" in output
    assert "hold_begin->hold_end: n=1 p50_ms=0.050" in output
    assert "hold_end->tree_sync_begin: n=1 p50_ms=0.030" in output
    assert "overlay_update_begin->overlay_update_end: n=1 p50_ms=0.080" in output
    assert "overlay_update_end->tree_sync_begin: n=1 p50_ms=0.010" in output
    assert "managed_update_display_applied->display_rendered: n=1 p50_ms=0.300" in output
    assert "record_presentation_begin->view_presented: n=1 p50_ms=0.800" in output
    assert "topology_installed->interactive_ready: n=1 p50_ms=5.000" in output
    assert (
        "registry_callback_begin->topology_installed registry.notifyChanged.begin count: "
        "n=1 p50_count=1.0"
    ) in output
    assert (
        "topology_installed->interactive_ready registry.notifyChanged.begin count: "
        "n=1 p50_count=0.0"
    ) in output
    assert (
        "topology_installed->interactive_ready model.surfaceRegistryRevision.published count: "
        "n=1 p50_count=1.0"
    ) in output
    assert (
        "send_end->interactive_ready tmux.query.list_windows.send count: "
        "n=1 p50_count=1.0"
    ) in output
    assert (
        "send_end->interactive_ready tmux.query.pane_metadata.response_processed count: "
        "n=1 p50_count=1.0"
    ) in output
    assert (
        "send_end->interactive_ready tmux.query.pane_state.response_processed count: "
        "n=1 p50_count=0.0"
    ) in output
    assert (
        "send_end->interactive_ready tmux.query.pane_visible.send count: "
        "n=1 p50_count=2.0"
    ) in output
    assert (
        "send_end->interactive_ready tmux.query.pane_visible.response_processed count: "
        "n=1 p50_count=2.0"
    ) in output
    assert (
        "view_presented->runtime_presentation_ready: "
        "n=0 missing=0 out_of_order=1"
    ) in output
    assert "last_presentation_fact->interactive_ready: n=1 p50_ms=1.000" in output
    assert "[native.surfaceInit all] surfaces=2 samples=4" in native_output
    assert "native.coreSurface.renderer.init: n=1 p50_ms=0.500" in native_output
    assert "native.coreSurface.termio.init: n=1 p50_ms=2.000" in native_output
    assert "native.coreSurface.assignState: n=2 p50_ms=0.150" in native_output


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Summarize Remux tmux topology flow segment timings."
    )
    parser.add_argument("logs", nargs="*", type=Path, help="Unified log text exports")
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run the built-in parser smoke test",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        run_self_test()
        return 0

    if not args.logs:
        print("no log files supplied", file=sys.stderr)
        return 2

    missing = [path for path in args.logs if not path.is_file()]
    if missing:
        for path in missing:
            print(f"missing log file: {path}", file=sys.stderr)
        return 2

    print(report(group_flow_instances(parse_events(args.logs))))
    native_report = report_native_surface_init(parse_native_surface_init_events(args.logs))
    if native_report != "native_surface_init_traces=0":
        print()
        print(native_report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
