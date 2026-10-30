# Quelle: https://github.com/kenantan32/sidestore-healthkit (patch_healthkit.py)
# Let SideStore enable HealthKit on free (personal-team) App IDs.
# Apple allows HealthKit on free teams; SideSign's allowlist just omits it.
import pathlib, sys

f = pathlib.Path("Dependencies/SideSign/Sources/Models/Feature.swift")
s = f.read_text()
edits = [
    ("    public init?(entitlement: Entitlement) {\n",
     "    public init?(entitlement: Entitlement) {\n"
     "        if entitlement.rawValue == \"com.apple.developer.healthkit\" { self = .healthKit; return }\n"),
    ('    static let increasedDebuggingMemoryLimit: Feature   = "increasedDebuggingMemoryLimit"\n',
     '    static let increasedDebuggingMemoryLimit: Feature   = "increasedDebuggingMemoryLimit"\n'
     '    static let healthKit: Feature                       = "HK421J6T7P"\n'),
    ("    static let freeFeatures: Set<Feature> = [\n        .appGroups,\n",
     "    static let freeFeatures: Set<Feature> = [\n        .healthKit,\n        .appGroups,\n"),
    ("    static let paidFeatures: Set<Feature> = [\n        .appGroups,\n",
     "    static let paidFeatures: Set<Feature> = [\n        .healthKit,\n        .appGroups,\n"),
]
for old, new in edits:
    if s.count(old) != 1:
        sys.exit(f"patch anchor not found exactly once: {old!r}")
    s = s.replace(old, new)
f.write_text(s)

e = pathlib.Path("Dependencies/SideSign/Sources/Models/Entitlement.swift")
t = e.read_text()
old = "    static let freeEntitlements: Set<Entitlement> = [\n        .appGroups,\n"
if t.count(old) != 1:
    sys.exit("freeEntitlements anchor not found")
e.write_text(t.replace(old, old + "        \"com.apple.developer.healthkit\",\n        \"com.apple.developer.healthkit.access\",\n"))
print("patched")
