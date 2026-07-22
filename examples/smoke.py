#!/usr/bin/env python3
"""Build and exercise both example collections through Automation Bridge."""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "automation_bridge" / "automation-bridge-python"))

from automation_bridge import editor, engine  # noqa: E402


def reboot_into(game: engine.Client, collection: str) -> None:
    game.reboot(
        f"--config=bootstrap.main_collection={collection}",
        "build/default/game.projectc",
    )


def main() -> None:
    project = editor.open_project(ROOT)
    game = project.build_and_run(
        timeout=60,
        required_capabilities=["scene", "input.drag", "screenshot", "application.state"],
    )
    try:
        health = game.health()
        assert health["debug"] is True

        reboot_into(game, "/examples/voronoi/voronoi.collectionc")
        game.wait_for_state("example.voronoi.ready", True)
        before = game.screenshot(wait=True)
        game.drag((115, 490), (210, 410), duration=0.25, visualize=False)
        after = game.screenshot(wait=True)
        assert before.sha256 != after.sha256, "Voronoi example did not change after moving a site"

        reboot_into(game, "/examples/multicamera/multicamera.collectionc")
        game.wait_for_state("example.multicamera.ready", True)
        assert game.count(name="camera", type="camerac") == 3
        first = game.screenshot(wait=True)
        game.drag((180, 300), (260, 220), duration=0.25, visualize=False)
        second = game.screenshot(wait=True)
        assert first.sha256 != second.sha256, "multi-camera example did not change after moving P1"
        print("Automation Bridge smoke test passed for both examples")
    finally:
        game.close_engine()


if __name__ == "__main__":
    main()
