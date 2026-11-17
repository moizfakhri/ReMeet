# Design sources

`AppIcon.icon` is the Icon Composer (macOS layered glass) grille source (Concept B).
Xcode's actool left 16/32/64 AppIcon slots as ~330-byte stubs, which made Dock
notifications blank. The shipping icon is the rasterized
`ReMeet/Assets.xcassets/AppIcon.appiconset`, generated from that grille. Re-export
from Icon Composer into the appiconset when small-slot rasterization is reliable.
