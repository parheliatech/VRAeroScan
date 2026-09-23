"""Mirror of AircraftClassifier.cs, run against live data to measure coverage."""
import json, urllib.request, collections

MIL_TYPES={"F16","F15","F18","F22","F35","A10","EUFI","RFAL","GR4","HAWK","C130","C30J",
"C17","C5M","K35R","KC46","A400","C27J","P8","E3TF","E3CF","E6","RC35","U2","P3","T6",
"T38","T45","B52","B1","B2"}
ROTOR={"R44","R22","R66","B06","B407","B429","EC30","EC35","EC45","AS50","A139","S76",
"H60","UH60","CH47","AH64","H500","MD52"}
BIZJET={"C25A","C25B","C25C","C25M","C500","C510","C525","C550","C551","C560","C56X",
"C650","C680","C68A","C700","C750","F900","F2TH","F7X","F8X","FA10","FA20","FA50",
"LJ31","LJ35","LJ40","LJ45","LJ55","LJ60","LJ70","LJ75","CL30","CL35","CL60","CL64",
"GLEX","GL5T","GL7T","GLF3","GLF4","GLF5","GLF6","G150","G280","E50P","E55P","E545",
"E550","HDJT","PRM1","BE40","H25B","HA4T"}
PISTON={"C150","C152","C162","C172","C177","C182","C185","C206","C207","C210","C310",
"C337","C402","C404","C414","C421","P28A","P28B","P28R","P28T","PA18","PA22","PA24",
"PA27","PA28","PA30","PA31","PA32","PA34","PA44","PA46","BE33","BE35","BE36","BE55",
"BE58","BE76","SR20","SR22","S22T","SR2T","DA20","DA40","DA42","DA62","M20P","M20T",
"AA5","GA7","RV6","RV7","RV8","RV9","RV10","RV14","J3","CH7B","BL8","C82R","COL4","LNC2"}
TURBO={"PC12","PC24","TBM7","TBM8","TBM9","B350","BE20","BE9L","C208","DH8A","DH8B",
"DH8C","DH8D","AT72","AT75","AT76","AT43","AT45","SF34","E120","SW4","D228","L410"}
MIL_CS=("RCH","EVAC","CNV","SENTRY","DOOM","POLO","SPAR")

def airliner(t):
    if not (3 <= len(t) <= 4): return False
    if t[0] not in "ABE": return False
    if not (t[1].isdigit() and t[2].isdigit()): return False
    if len(t)==4 and not t[3].isalnum(): return False
    return True

def mil_cs(cs): return bool(cs) and any(cs.strip().upper().startswith(p) for p in MIL_CS)

def classify(a):
    cat=a.get("category"); t=(a.get("t") or "").upper(); cs=a.get("flight")
    if cat and cat[0]=="C": return set()   # surface vehicle
    r=set()
    if cat=="A7":
        base={"Rotorcraft"}
        base.add("Military" if (t in MIL_TYPES or mil_cs(cs)) else "Private"); return base
    if cat=="B1": return {"Glider","Private"}
    if cat=="B6": return {"Drone"}
    if cat=="A1": r.add("Private")
    elif cat=="A2": r.add("Jet")
    elif cat in ("A3","A4","A5"): r|={"Commercial","Jet"}
    elif cat=="A6": r|={"Military","Jet"}
    if t:
        if t in MIL_TYPES: r.add("Military")
        if t in ROTOR: r.add("Rotorcraft")
        if t in PISTON: r.add("Piston")
        if t in TURBO: r.add("Turboprop")
        if t in BIZJET: r|={"Jet","Private"}
        if airliner(t): r|={"Jet","Commercial"}
    if mil_cs(cs): r.add("Military")
    if "Military" in r: r-={"Commercial","Private"}
    if "Piston" in r or "Turboprop" in r: r-={"Jet"}
    return r

tot=collections.Counter(); unknown=[]; n=0; surface=0
for lat,lon,name in [(34.0,-118.2,"LA"),(40.7,-74.0,"NYC"),(51.5,-0.1,"London"),(25.8,-80.3,"Miami")]:
    with urllib.request.urlopen(f"https://api.adsb.lol/v2/point/{lat}/{lon}/250",timeout=60) as r:
        ac=json.load(r).get("ac",[])
    for a in ac:
        if "lat" not in a: continue
        n+=1; c=classify(a)
        if a.get("category","").startswith("C"): surface+=1; continue
        if not c: unknown.append((a.get("t"),a.get("category"),(a.get("flight") or "").strip()))
        for k in c: tot[k]+=1

print(f"sampled {n} aircraft across 4 metros\n")
print("class coverage (flags can overlap):")
for k,v in tot.most_common(): print(f"  {k:<12}{v:>5}")
print(f"\nsurface vehicles correctly excluded: {surface}")
print(f"unclassified: {len(unknown)}  ({100*len(unknown)/max(n,1):.1f}%)")
if unknown:
    print("\nunclassified sample (type, category, callsign):")
    for u in collections.Counter(unknown).most_common(15): print("  ",u[0],"x",u[1])
