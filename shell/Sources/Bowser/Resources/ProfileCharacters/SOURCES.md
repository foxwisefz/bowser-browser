# Profile sprites

The PNG sprite sheets were supplied by the user on 2026-09-07 and
are bundled byte-for-byte, including their original alpha channels.
They replace all previously downloaded Mario Kart portraits.

| Bundled sheet | Supplied filename | Characters, in reading order |
| --- | --- | --- |
| originals.png | Gemini_Generated_Image_78iok578iok578io-removebg-preview.png | Mario, Luigi, Peach, Yoshi, Toad, Bowser |
| friends.png | Gemini_Generated_Image_hfueechfueechfue-removebg-preview (1).png | Wario, Waluigi, Daisy, Donkey Kong, Diddy Kong, Rosalina |
| adventurers.png | Gemini_Generated_Image_zfy36qzfy36qzfy3-removebg-preview.png | Captain Toad, Toadette, Birdo, Bowser Jr., Kamek, Shy Guy |
| friendly-bowser.png | Gemini_Generated_Image_dhus7ydhus7ydhus-removebg-preview.png | Bottom-right friendly Bowser replaces the original Bowser only |

`ProfileCharacter.sprite` identifies each portrait's rectangle. Runtime
cropping excludes the sheet's grid dividers without changing the source
files; SwiftUI uses nearest-neighbor interpolation for the pixel artwork.

`bin/build-icon` also uses the friendly Bowser sprite, including its heart,
to generate `assets/AppIcon.icns` and `assets/AppIcon.png` at native macOS
icon sizes. The other 17 profile portraits keep their previous sheets.
The friendly sheet's residual background-removal matte is discarded at
render time in both the profile loader and icon builder: low alpha pixels
(below 200), plus non-opaque dark neutral pixels (maximum premultiplied
channel 60, RGB spread at most 8) that
form the lower-left shadow. The colored navy outline stays intact.
The bundled source remains unmodified.
