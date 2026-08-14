import { copyFile } from "node:fs/promises"

await copyFile("CHANGELOG.md", "Hex/Resources/changelog.md")
