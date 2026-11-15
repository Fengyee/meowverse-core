# Model attribution and template modifications

The untextured cat geometry and its rendered guide images are derived from
**“3d modelling my cat: Fripouille” by guillaume bolis (2020)**.

- Original model: https://sketchfab.com/3d-models/3d-modelling-my-cat-fripouille-0ab14bf98e754f8d90fe1bf1c84ca66c
- Author: https://sketchfab.com/guillaume.bolis
- License: Creative Commons Attribution 4.0 International (CC BY 4.0)
- License URL: https://creativecommons.org/licenses/by/4.0/

The starting asset was the adapted model already used by Meowverse:
https://fengyee.github.io/meowverse/cat/bella.glb

Meowverse's existing adaptation aligned the body, eyes, and whiskers, normalized
the rig for room use, repainted the coat on the original UV layout, and created
eye and pose states. Its existing attribution is at:
https://github.com/Fengyee/meowverse/blob/gh-pages/licenses/bella-cat.txt

## Changes for this reference kit

- Removed the personalized coat textures, original eye textures, and whiskers.
- Baked one neutral standing pose and leveled the paw soles.
- Straightened the rearward tail and reduced residual deformation curvature.
- Welded coincident surface vertices, corrected normals, and smoothed the mesh.
- Applied neutral matte clay materials, fixed orthographic cameras, and a solid
  #BFBFBF background.
- Rendered five full-body directions and three head-and-neck close-ups.

These are modified reference assets. They do not imply endorsement by the
original author. Preserve this attribution and the license link when
redistributing the geometry or rendered guide images. The template geometry
and its rendered derivatives are supplied under CC BY 4.0.
