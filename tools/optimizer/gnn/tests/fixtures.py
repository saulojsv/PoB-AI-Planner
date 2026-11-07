from __future__ import annotations

def run_spec():
    return {
        "schemaVersion": 1, "modelMode": "approved_or_fallback", "modelPackageId": None,
        "searchMode": "SINGLE_SKILL_ONLY",
        "skill": {"groupIndex": 1, "skillIndex": 1, "effectId": "IceSpear", "gemId": "Metadata/Items/Gems/SkillGemIceSpear", "slot": "Body Armour"},
        "scenario": {"profile": "Current", "enemyPreset": "Active"},
        "targets": {"dps": "TIER_10M_TO_25M", "ehp": "TIER_50K_TO_100K", "elementalMaxHit": "TIER_10K_TO_20K", "physicalMaxHit": "TIER_10K_TO_20K"},
        "resistances": {"elemental": "CAP_EFFECTIVE", "chaos": "POSITIVE_OR_CAP"},
        "crossSkillMode": "SINGLE_SKILL_ONLY", "mutationAggressiveness": "BALANCED_LOCAL_SEARCH",
        "graph": {"radius": 4}, "budget": {"minProposals": 1000, "maxExactEvaluations": 5000, "timeoutSeconds": 1800},
    }

def snapshot():
    return {
        "schemaVersion": 1,
        "engine": {"pobVersion": "2.67.2", "pobBranch": "dev", "dataVersion": "3.29", "treeVersion": "3_29", "manifestFingerprint": "a" * 64},
        "skill": run_spec()["skill"], "scenario": run_spec()["scenario"],
        "passiveNodes": [{"id": 1, "allocated": True, "category": "notable"}, {"id": 2, "allocated": False, "category": "passive"}],
        "passiveEdges": [{"source": 1, "target": 2}], "items": [],
        "skillGroups": [{"index": 1, "slot": "Body Armour", "enabled": True, "includedInFullDPS": True,
                         "gems": [{"gemId": run_spec()["skill"]["gemId"], "effectId": "IceSpear", "level": 20, "quality": 20, "origin": "socketed_gem", "support": False}]}],
        "baselineMetrics": {"CombinedDPS": 12000000.0, "TotalEHP": 55000.0},
    }

def proposal(proposal_id="p1", added=None):
    return {"proposalId": proposal_id, "family": "tree", "addedNodeIds": added or [], "removedNodeIds": [],
            "changedItemSlots": [], "featureTokens": ["family:tree"], "numericFeatures": [1, 0]}

def row(lineage="lineage-1", record_id="record-1", set_id="set-1", proposal_index=0):
    spec = run_spec()
    metrics = {"exactCalculated": True, "feasible": True, "CombinedDPS": 12_000_000.0, "FullDPS": 12_000_000.0,
               "TotalEHP": 55_000.0, "PhysicalMaximumHitTaken": 11_000.0,
               "FireMaximumHitTaken": 11_000.0, "ColdMaximumHitTaken": 12_000.0, "LightningMaximumHitTaken": 13_000.0,
               "FireResist": 75.0, "ColdResist": 75.0, "LightningResist": 75.0, "ChaosResist": 0.0}
    return {"schemaVersion": 1, "recordId": record_id, "lineageId": lineage, "setId": set_id, "proposalIndex": proposal_index,
            "sourceReview": {"rights": "authorized", "rightsBasis": "user_authored", "consent": True, "reviewed": True, "reviewer": "QA", "evidence": "explicit local authorization"},
            "nativeValidation": {key: True for key in ("exactRecalculated", "skillCompatible", "resourcesValid", "scenarioCertified", "metricsContextValid", "triggerCertified", "unsupportedModesAbsent")},
            "engine": snapshot()["engine"], "skill": spec["skill"], "scenario": spec["scenario"], "runSpec": spec,
            "buildSnapshot": snapshot(), "proposal": proposal("p" + str(proposal_index + 1)), "exactMetrics": metrics}
