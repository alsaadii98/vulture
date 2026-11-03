# Writing cleaning rules

A rule tells Vulture where a kind of removable file lives and how to describe it to someone who has never heard of a cache. Rules are data: they can't run code, and they can't reach outside the home folder.

Rule files live in `Sources/VultureCore/Rules/*.json`:

```json
{
  "schemaVersion": 1,
  "rules": [
    {
      "id": "xcode.derived-data",
      "title": "Xcode build files",
      "explanation": "Xcode keeps a copy of every project it builds so the next build is faster. It makes them again the next time you build.",
      "category": "developer",
      "safety": "safe",
      "regrows": "onNextBuild",
      "paths": ["~/Library/Developer/Xcode/DerivedData/*"],
      "closeFirst": ["com.apple.dt.Xcode"]
    }
  ]
}
```

## Fields

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Lowercase dotted name, `group.name`. Never reuse or rename one. |
| `title` | yes | Up to 40 characters. What a person would call these files. |
| `explanation` | yes | Up to 200 characters. What the files are and what happens if they're removed. No jargon. |
| `category` | yes | `appFiles`, `logs`, `developer`, `downloads` or `mail` |
| `safety` | yes | `safe` (selected by default: apps make these again) or `review` (offered, but the person decides) |
| `regrows` | yes | `never`, `onNextUse`, `onNextBuild` or `onNextInstall`: when the space gets used again |
| `paths` | yes | Patterns starting with `~/`. `*`, `?` and `[…]` match within one folder name; `*` skips hidden items. No `**`. |
| `exclude` | no | Name patterns to ignore among the matches |
| `minAgeDays` | no | Only offer an item if nothing inside it changed (or was added) for this many days |
| `closeFirst` | no | Bundle IDs of apps that must be closed first |
| `entryNameIsBundleID` | no | Each match is named after an app's bundle ID; skip it while that app runs |
| `priority` | no | Higher runs first and claims its matches. Broad catch-alls use a negative number. |

## What Vulture checks for you

`vulture check-rules DIR` and the test suite reject a rule when:

- a pattern doesn't start with `~/`, uses `..`, starts with a wildcard folder, or names a whole home folder like `~/Downloads`;
- a pattern points inside a protected place (see `SafetyPolicy.standardProtectedPaths`);
- the id, title or explanation breaks the limits above, or two rules share an id.

While scanning, every match is checked again: protected places, symbolic links and folders reached through a link are never offered, however a rule is written.

## Choosing `safe` or `review`

Use `safe` only when the owning app recreates the files by itself and nothing the person made is lost. Anything that can't come back, takes a long time to rebuild, or might hold someone's work is `review`.

## Publishing rule updates

Rules can be updated without a new app release, as a signed pack:

```sh
vulture rules keygen --out ~/secure-place          # once; keep the private key offline
vulture rules pack Sources/VultureCore/Rules --version 2026.12.01 --key ~/secure-place/vulture-rules-XXXX.key --out rules-2026.12.01.vulturerules
vulture rules install rules-2026.12.01.vulturerules
```

Vulture only uses a pack when a public key in `RuleUpdates.trustedKeys` verifies its signature, its version is newer than the rules in use, and every rule passes the checks above. The list of trusted keys is empty until the project publishes its first key, so today only the built-in rules are used. Vulture never downloads rules by itself.
