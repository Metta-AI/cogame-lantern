## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "lantern-rules-v1"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc introduction*(selection: PromptSelection): string =
  case selection.selectedVariant
  of pvCanonical: "You are one cog in a 3v3 hide-and-seek match on a dark warehouse floor, 1235 by 659\npixels, x right, y down."
  of pvPlain: "You control one cog in 3v3 hide-and-seek on a dark warehouse floor.\nThe floor is 1235 by 659 pixels; x increases right and y increases down."
  of pvNumbered: "1. You control one cog in a 3v3 hide-and-seek match.\n2. The setting is a dark warehouse floor, 1235 by 659 pixels.\n3. Coordinates increase right for x and down for y."
  of pvQuestions: "Who are you? One cog in a 3v3 hide-and-seek match.\nWhere? A dark warehouse floor, 1235 by 659 pixels.\nHow are coordinates oriented? x right, y down."
  of pvReordered: "The dark warehouse floor measures 1235 by 659 pixels, with x right and y down.\nYou control one cog in the 3v3 hide-and-seek match played here."
  of pvHeldoutBriefing: "Match briefing: play one cog in 3v3 hide-and-seek on a dark warehouse floor.\nFloor dimensions are 1235 by 659 pixels. The x axis points right; the y axis points down."
  of pvHeldoutReference: "Assignment: one cog. Match: 3v3 hide-and-seek. Location: dark warehouse floor.\nDimensions: 1235 by 659 pixels. Coordinates: x right, y down."
  of pvMixed: raise newException(Defect, "unresolved mixed wording")
