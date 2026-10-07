# Slots & Daggers: decompile / extract toolkit

Turns a local Steam install of *Slots & Daggers* into a study bundle another AI can read:
decompiled source, a file inventory, a ranked list of the files with the core logic, and one
concatenated `ALL_SOURCE.txt`.

## Run (Windows, on the PC that has the game)

```powershell
cd slots-and-daggers-re
powershell -ExecutionPolicy Bypass -File .\extract.ps1
# or with explicit paths:
powershell -ExecutionPolicy Bypass -File .\extract.ps1 -GameDir "D:\Steam\steamapps\common\Slots and Daggers" -OutDir .\sd_extract
```

Output goes to `sd_extract\`, then open `STUDY_GUIDE.md`.

## What it does

1. **Inventory**: every shipped file, its size and SHA256 (`inventory.csv`, `file_tree.txt`).
2. **Engine detection**: Unity (Mono / IL2CPP), Godot (separate or embedded `.pck`), GameMaker,
   Electron, Love2D, Unreal, RPG Maker.
3. **Decompile with open-source tools** (downloaded into `sd_extract\_tools` the first time):
   | Engine | Tool | Result |
   |---|---|---|
   | Godot | [GDRE Tools](https://github.com/GDRETools/gdsdecomp) | Full project: `.gd` scripts, scenes, resources |
   | Unity Mono | `ilspycmd` (needs .NET 8 SDK) | C# projects for the game assemblies |
   | Unity IL2CPP | [Il2CppDumper](https://github.com/Perfare/Il2CppDumper) | Class and method signatures, Ghidra script |
   | Electron / Love2D | asar / zip extract | Original JS / Lua |
   | GameMaker, Unreal, RPG Maker | manual steps printed in STUDY_GUIDE.md | |
4. **Study bundle**: `ALL_SOURCE.txt` (capped by `-MaxBundleMB`, default 40), `source_index.csv`,
   keyword-ranked "core logic" files (reels, symbols, damage, items, RNG, save…), and a ready-made
   prompt for the AI.

Flags: `-SkipTools` rebuilds the inventory and bundle only. Use it after doing a manual export
into `sd_extract\decompiled`.

## Notes
- The output is the developer's copyrighted code and assets. Keep it for private study and
  **don't commit `sd_extract/` to a public repo**. It's already in `.gitignore`.
- To share with the AI, attach `ALL_SOURCE.txt` and `STUDY_GUIDE.md`. If the bundle is too big,
  start with the top-ranked files from the guide.
