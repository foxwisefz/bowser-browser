# Application icon artwork

`AppIconArtwork.png` is the user's supplied image
`Gemini_Generated_Image_e884yue884yue884-removebg-preview.png`, copied
unchanged on 2026-09-07.

Run `bin/build-icon` to generate `AppIcon.icns` and the 1024px `AppIcon.png`
preview. The builder trims empty outer margins (bounds measured at alpha
above 10 with two source pixels of padding), preserves proportions and
the alpha channel, uses smooth scaling, and centers it with 6% padding
on each side of its longest dimension. This artwork is independent of
the profile sprites.
