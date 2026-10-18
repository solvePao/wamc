# WAMC product website

Buildless HTML, CSS, and local SVG artwork. Preview from the repository root with
`python3 -m http.server 8765 --directory website`, then open http://localhost:8765.

The Product website workflow publishes only this directory to GitHub Pages from
`main`. Enable GitHub Actions as the Pages publishing source in repository
settings. Publication requires an anonymously accessible stable release in
`solvePao/wamc-releases` with a nonempty APK and `-arm64.dmg` asset. If releases are
unavailable, publication fails before uploading or deploying. After publishing
paired binaries, rerun the workflow manually; binary publication does not trigger
this source repository’s workflow.

Download links point to the latest public release rather than versioned assets.
Keep requirements and compatibility claims aligned with validated product behavior.
The device artwork is an illustration, not a screenshot.
