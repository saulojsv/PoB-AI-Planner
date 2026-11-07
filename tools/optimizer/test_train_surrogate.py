"""Focused safety and fail-closed tests for the optional PoB ranker trainer."""

from __future__ import annotations

import json
import pathlib
import tempfile
import unittest
from unittest import mock

import train_surrogate as trainer


ENGINE = {"pobVersion": "3.29.0", "pobBranch": "dev", "dataVersion": "3.29", "treeVersion": "3_29",
          "manifestFingerprint": "a" * 64, "lookupTableStatus": "certified"}


def row(split: str, group: str, node_id: int, delta: float) -> dict:
    return {
        "recordType": "exact_pair",
        "split": split,
        "sourceGroupId": group,
        "engine": ENGINE,
        "features": {
            "class": "Witch", "classId": 2, "ascendancy": "Elementalist", "ascendancyId": 5,
            "characterLevel": 90, "mainSkill": "Fireball", "supportFeatureSchemaVersion": 2, "allocatedNodeIds": [101, 102],
            "masterySelections": [], "skillGroups": [
                {"groupIndex": 1, "slot": "Body Armour", "enabled": True, "slotEnabled": True,
                 "includeInFullDPS": True, "selectedMainGroup": True, "supportProfileVersion": 2,
                 "socketValidation": {"valid": True, "status": "linked"},
                 "gems": [
                     {"gemId": "SkillGemFireballTransfig", "gameId": "Metadata/Items/Gems/SkillGemFireball",
                      "skillId": "FireballTransfig", "level": 20, "quality": 20, "enabled": True, "isSupport": False, "socketMatched": True},
                     {"gemId": "SupportAddedFireDamage", "gameId": "Metadata/Items/Gems/SupportAddedFireDamage",
                      "level": 20, "quality": 20, "enabled": True, "isSupport": True, "socketMatched": True},
                 ]},
            ], "itemSlots": [{"slot": "Body Armour", "base": "Vaal Regalia", "rarity": "RARE"}],
            "kind": "passive_node_pair",
            "experiment": {"unit": "one_passive_node", "addedNodeIds": [node_id], "removedNodeIds": []},
            "baselineMetrics": {"CombinedDPS": 1000, "TotalEHP": 5000},
        },
        "labels": {"CombinedDPS": delta, "TotalEHP": delta / 10},
    }


def header(training: int, holdout: int, training_groups: int, holdout_groups: int) -> dict:
    return {
        "recordType": "dataset_header", "format": trainer.FORMAT,
        "datasetSchemaVersion": trainer.SCHEMA_VERSION, "featurePolicy": trainer.FEATURE_POLICY,
        "groupingPolicy": trainer.GROUPING_POLICY,
        "engine": ENGINE, "sourceLineages": training_groups + holdout_groups,
        "trainingSourceLineages": training_groups, "holdoutSourceLineages": holdout_groups,
        "trainingRows": training,
        "holdoutRows": holdout, "popularityFeaturesExcluded": True,
        "modelTrainingEnabled": False, "qualityGate": {"minimumSpearman": 0.8, "minimumTopParetoRecall": 0.9},
    }


class TrainerSafetyTests(unittest.TestCase):
    def test_hash_matches_runtime_polynomial(self):
        value = 0
        for byte in b"added-node:103":
            value = (value * 131 + byte) % trainer.HASH_MODULUS
        self.assertEqual(value % 256 + 1, trainer.hash_token("added-node:103", 256))

    def test_feature_projection_rejects_other_experiment_families(self):
        features = row("train", "g1", 201, 10)["features"]
        projection = trainer.project_features(features, "CombinedDPS")
        self.assertIsNotNone(projection)
        self.assertIn("configured-skill-effect:FireballTransfig", projection["tokens"])
        self.assertIn("support:game:Metadata/Items/Gems/SupportAddedFireDamage", projection["tokens"])
        self.assertIn("equipped-item-base:Body Armour:Vaal Regalia", projection["tokens"])
        features["kind"] = "item_slot_pair"
        self.assertIsNone(trainer.project_features(features, "CombinedDPS"))

    def test_context_schema_rejects_unbounded_or_unknown_nested_fields(self):
        features = row("train", "g1", 201, 10)["features"]
        features["skillGroups"][0]["providerRank"] = 1
        self.assertIsNone(trainer.project_features(features, "CombinedDPS"))
        features = row("train", "g1", 201, 10)["features"]
        features["itemSlots"] = [{"slot": "Body Armour", "rawItemText": "not an approved feature"}]
        self.assertIsNone(trainer.project_features(features, "CombinedDPS"))

    def test_versioned_item_granted_supports_preserve_target_and_full_item_identity_tokens(self):
        features = row("train", "g1", 201, 10)["features"]
        fingerprint = "d" * 64
        group = features["skillGroups"][0]
        group["supportProfileVersion"] = 2
        group["socketValidation"] = {"valid": True, "status": "linked"}
        group["gems"][0]["variantId"] = "FireballTransfig"
        group["skills"] = [{
            "skillIndex": 1, "selectedMainSkill": True, "supportProfileVersion": 2,
            "effects": [{"effectId": "Fireball", "selected": True}],
            "supports": [{
                "gemId": "Metadata/Items/Gems/SupportHypothermia",
                "gameId": "Metadata/Items/Gems/SupportGemHypothermia",
                "variantId": "Hypothermia", "skillId": "SupportHypothermia",
                "effectId": "SupportHypothermia", "name": "Hypothermia",
                "level": 15, "quality": 0, "origin": "item_granted", "sourceSlot": "Body Armour",
                "sourceItemFingerprint": fingerprint, "targetGroupIndex": 1, "targetSkillIndex": 1,
                "targetEffectId": "Fireball", "active": True, "configured": True, "calculatorApplied": True,
                "socketMatched": False, "socketState": "not_applicable", "linkState": "verified_item_local",
                "groupState": "active", "playableActive": True, "supportProfileVersion": 2,
            }],
        }]
        features["itemSlots"][0]["itemFingerprint"] = fingerprint
        projection = trainer.project_features(features, "CombinedDPS")
        self.assertIsNotNone(projection)
        for token in (
            "support-profile:v2", "skill-support-profile:v2", "main-skill-support-profile:v2",
            "support-origin:item_granted", "support-effect:SupportHypothermia",
            "support-target-effect:Fireball", "support-target-group:1", "support-target-skill-index:1",
            "support-source-slot:Body Armour", f"support-source-item:{fingerprint}",
            "support-level:15", f"equipped-item-fingerprint:Body Armour:{fingerprint}",
        ):
            self.assertIn(token, projection["tokens"])
        group["skills"][0]["supports"][0]["unapprovedFeature"] = "reject"
        self.assertIsNone(trainer.project_features(features, "CombinedDPS"))

    def test_legacy_v1_supports_are_readable_but_never_become_support_tokens(self):
        features = row("train", "g1", 201, 10)["features"]
        features["supportFeatureSchemaVersion"] = 1
        group = features["skillGroups"][0]
        group["supportProfileVersion"] = 1
        group.pop("socketValidation")
        group["gems"][1]["socketMatched"] = False
        group["skills"] = [{"skillIndex": 1, "selectedMainSkill": True, "supportProfileVersion": 1,
                             "supports": [{"effectId": "SupportAddedFireDamage", "active": True,
                                           "supportProfileVersion": 1}]}]
        projection = trainer.project_features(features, "CombinedDPS")
        self.assertIsNotNone(projection)
        tokens = set(projection["tokens"])
        self.assertIn("support-profile:legacy-unknown", tokens)
        self.assertNotIn("support:game:Metadata/Items/Gems/SupportAddedFireDamage", tokens)
        self.assertNotIn("support-effect:SupportAddedFireDamage", tokens)

    def test_v2_playable_support_requires_consistent_socket_and_link_evidence(self):
        features = row("train", "g1", 201, 10)["features"]
        group = features["skillGroups"][0]
        group["skills"] = [{"skillIndex": 1, "selectedMainSkill": True, "supportProfileVersion": 2,
                             "supports": [{"effectId": "SupportAddedFireDamage", "active": True,
                                           "configured": True, "calculatorApplied": True, "socketMatched": True,
                                           "socketState": "invalid", "linkState": "validated_link",
                                           "groupState": "active", "playableActive": True,
                                           "supportProfileVersion": 2}]}]
        self.assertIsNone(trainer.project_features(features, "CombinedDPS"))

    def test_context_ranker_keeps_the_same_single_hidden_layer_dimensions(self):
        self.assertEqual("passive-one-node-build-context-mlp-v2", trainer.MODEL_TYPE)
        self.assertEqual(1024, trainer.FEATURE_DIMENSION)
        self.assertEqual(6, trainer.SCHEMA_VERSION)
        self.assertEqual(7, trainer.ARTIFACT_SCHEMA_VERSION)

    def test_domain_requires_a_joint_class_ascendancy_skill_and_node_observation(self):
        fireball = self._rank_row("train-a", 10, 1)
        arc = self._rank_row("train-b", 20, 2)
        fireball["feature"].update(classId=2, ascendancyId=5, mainSkill="Fireball", changedNodeIds=[201])
        arc["feature"].update(classId=4, ascendancyId=8, mainSkill="Arc", changedNodeIds=[202])
        domain = trainer._domain([fireball, arc])

        self.assertTrue(trainer._in_domain(fireball, domain))
        self.assertTrue(trainer._in_domain(arc, domain))
        cross_combination = self._rank_row("holdout", 15, 1.5)
        cross_combination["feature"].update(classId=2, ascendancyId=5, mainSkill="Arc", changedNodeIds=[201])
        self.assertFalse(trainer._in_domain(cross_combination, domain))

    def test_popularity_field_is_rejected_before_any_training(self):
        with tempfile.TemporaryDirectory() as directory:
            dataset = pathlib.Path(directory) / "dataset.jsonl"
            output = pathlib.Path(directory) / "active.json"
            record = row("train", "g1", 201, 10)
            record["features"]["popularityRank"] = 1
            dataset.write_text("\n".join(json.dumps(value) for value in [header(1, 1, 1, 1), record, row("holdout", "g2", 202, 12)]) + "\n", encoding="utf-8")
            with self.assertRaises(trainer.DatasetError):
                trainer.train(dataset, output, "CombinedDPS")
            self.assertFalse(output.exists())

    def test_small_corpus_fails_closed_without_creating_an_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            dataset = pathlib.Path(directory) / "dataset.jsonl"
            output = pathlib.Path(directory) / "active.json"
            values = [header(2, 2, 1, 1), row("train", "build-a", 201, 10), row("train", "build-a", 202, 12),
                      row("holdout", "build-b", 201, 9), row("holdout", "build-b", 202, 11)]
            dataset.write_text("\n".join(json.dumps(value) for value in values) + "\n", encoding="utf-8")
            result = trainer.train(dataset, output, "CombinedDPS")
            self.assertEqual("blocked_insufficient_source_lineages", result["status"])
            self.assertFalse(result["artifactWritten"])
            self.assertFalse(output.exists())

    def test_missing_or_malformed_manifest_fingerprint_fails_before_training(self):
        with tempfile.TemporaryDirectory() as directory:
            dataset = pathlib.Path(directory) / "dataset.jsonl"
            output = pathlib.Path(directory) / "active.json"
            invalid_engine = dict(ENGINE, manifestFingerprint="not-a-sha256")
            values = [header(2, 2, 1, 1), row("train", "build-a", 201, 10), row("holdout", "build-b", 202, 12)]
            values[0]["engine"] = invalid_engine
            values[1]["engine"] = invalid_engine
            values[2]["engine"] = invalid_engine
            dataset.write_text("\n".join(json.dumps(value) for value in values) + "\n", encoding="utf-8")
            with self.assertRaises(trainer.DatasetError):
                trainer.train(dataset, output, "CombinedDPS")
            self.assertFalse(output.exists())

    def test_trains_and_evaluates_on_disjoint_build_groups_but_rejects_inverted_holdout(self):
        with tempfile.TemporaryDirectory() as directory:
            dataset = pathlib.Path(directory) / "dataset.jsonl"
            output = pathlib.Path(directory) / "active.json"
            values = [header(128, 50, 8, 5)]
            for group_index in range(8):
                for row_index in range(16):
                    node_id = 201 + row_index
                    delta = 20 if node_id % 2 else -20
                    values.append(row("train", f"train-{group_index}", node_id, delta))
            for group_index in range(5):
                for row_index in range(10):
                    node_id = 201 + row_index
                    delta = -20 if node_id % 2 else 20
                    values.append(row("holdout", f"holdout-{group_index}", node_id, delta))
            dataset.write_text("\n".join(json.dumps(value) for value in values) + "\n", encoding="utf-8")
            result = trainer.train(dataset, output, "CombinedDPS", hidden_size=4, seed=9)
            self.assertEqual("failed", result["status"])
            self.assertEqual(8, result["trainingSourceLineages"])
            self.assertEqual(5, result["holdoutSourceLineages"])
            self.assertFalse(result["artifactWritten"])
            self.assertGreaterEqual(result["validation"]["heldOutRows"], 50)
            self.assertFalse(output.exists())

    def test_group_overlap_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            dataset = pathlib.Path(directory) / "dataset.jsonl"
            values = [header(1, 1, 1, 1), row("train", "same-build", 201, 10), row("holdout", "same-build", 202, 12)]
            dataset.write_text("\n".join(json.dumps(value) for value in values) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(trainer.DatasetError, "overlap"):
                trainer.load_dataset(dataset, "CombinedDPS")

    def test_legacy_dataset_schema_and_unknown_grouping_policy_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            dataset = pathlib.Path(directory) / "legacy.jsonl"
            legacy = header(1, 1, 1, 1)
            legacy["datasetSchemaVersion"] = 1
            legacy["featurePolicy"] = "exact-pair-allowlist-v1"
            dataset.write_text(json.dumps(legacy) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(trainer.DatasetError, "schema"):
                trainer.load_dataset(dataset, "CombinedDPS")

            current = header(1, 1, 1, 1)
            current["groupingPolicy"] = "unknown-source-grouping"
            dataset.write_text(json.dumps(current) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(trainer.DatasetError, "lineage policy"):
                trainer.load_dataset(dataset, "CombinedDPS")

    def test_declared_source_lineage_counts_must_match_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            dataset = pathlib.Path(directory) / "mismatch.jsonl"
            invalid = header(1, 1, 2, 1)
            values = [invalid, row("train", "train-a", 201, 10), row("holdout", "holdout-a", 202, 12)]
            dataset.write_text("\n".join(json.dumps(value) for value in values) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(trainer.DatasetError, "declared source-lineage"):
                trainer.load_dataset(dataset, "CombinedDPS")

    @staticmethod
    def _rank_row(group: str, delta: float, ehp_delta: float) -> dict:
        return {
            "group": group,
            "feature": {"classId": 2, "ascendancyId": 5, "mainSkill": "Fireball", "changedNodeIds": [201]},
            "target": delta,
            "targetDelta": delta,
            "ehpDelta": ehp_delta,
            "pointDelta": 1,
        }

    def test_pareto_recall_is_macro_averaged_within_each_baseline_group(self):
        train_rows = [self._rank_row("train", 1, 1)]
        # Within each build, the first row dominates the second. Across builds,
        # group-a's magnitudes dominate all of group-b, so pooling would erase
        # group-b from the global Pareto front and score only one build.
        holdout = [
            self._rank_row("group-a", 100, 100), self._rank_row("group-a", 90, 90),
            self._rank_row("group-b", 10, 10), self._rank_row("group-b", 0, 0),
        ]
        # The model reverses group-a but orders group-b correctly. Per-group
        # recall is therefore (0 + 1) / 2 = 0.5; pooled recall would be 0.
        predictions = trainer.np.asarray([20, 30, 10, 0], dtype=trainer.np.float64)
        with mock.patch.object(trainer, "_predict", return_value=predictions):
            result = trainer.evaluate((), train_rows, holdout, hidden_size=4, seed=9)

        self.assertEqual(0.5, result["topParetoRecall"])
        self.assertEqual(2, result["paretoScoredGroups"])
        self.assertEqual(0, result["paretoUnscoredGroups"])

    def test_model_must_not_regress_against_preserved_candidate_order(self):
        train_rows = [self._rank_row("train", 1, 1)]
        holdout = []
        predictions = []
        for group_index in range(10):
            group = f"group-{group_index}"
            # Input order is already Pareto-optimal. The model is correct for
            # nine groups and reverses the final group's two candidates.
            holdout.extend([self._rank_row(group, 100, 100), self._rank_row(group, 0, 0)])
            predictions.extend([1, 0] if group_index < 9 else [0, 1])
        with mock.patch.object(trainer, "_predict", return_value=trainer.np.asarray(predictions, dtype=trainer.np.float64)):
            result = trainer.evaluate((), train_rows, holdout, hidden_size=4, seed=9)

        # The model still clears the absolute 0.80/0.90 thresholds; it fails
        # solely because it is worse than the exact disabled-ranker ordering.
        self.assertAlmostEqual(0.8, result["heldOutSpearman"])
        self.assertAlmostEqual(0.9, result["topParetoRecall"])
        self.assertAlmostEqual(1.0, result["baselineInputOrderSpearman"])
        self.assertAlmostEqual(1.0, result["baselineInputOrderTopParetoRecall"])
        self.assertFalse(result["baselineNonRegression"])
        self.assertEqual("failed", result["status"])

    def test_trainer_writes_no_artifact_when_model_meets_absolute_gates_but_regresses(self):
        with tempfile.TemporaryDirectory() as directory:
            dataset = pathlib.Path(directory) / "dataset.jsonl"
            output = pathlib.Path(directory) / "active.json"
            values = [header(128, 50, 8, 10)]
            for group_index in range(8):
                for row_index in range(16):
                    delta = 40 if row_index % 2 else -40
                    values.append(row("train", f"train-{group_index}", 201 + row_index, delta))
            expected_scores = []
            for group_index in range(10):
                group = f"holdout-{group_index}"
                for row_index, delta in enumerate((100, 80, 60, 40, 20)):
                    values.append(row("holdout", group, 201 + row_index, delta))
                expected_scores.extend((5, 4, 3, 2, 1) if group_index < 9 else (1, 2, 3, 4, 5))
            dataset.write_text("\n".join(json.dumps(value) for value in values) + "\n", encoding="utf-8")

            # The model clears both absolute thresholds at 0.80/0.90, but it
            # loses to the persisted no-op order on both held-out measures.
            with mock.patch.object(trainer, "_fit_mlp", return_value=()):
                with mock.patch.object(trainer, "_predict", return_value=trainer.np.asarray(expected_scores, dtype=trainer.np.float64)):
                    result = trainer.train(dataset, output, "CombinedDPS", hidden_size=4, seed=9)

            self.assertEqual("failed", result["status"])
            self.assertAlmostEqual(0.8, result["validation"]["heldOutSpearman"])
            self.assertAlmostEqual(0.9, result["validation"]["topParetoRecall"])
            self.assertFalse(result["validation"]["baselineNonRegression"])
            self.assertFalse(result["artifactWritten"])
            self.assertFalse(output.exists())

    def test_model_passes_when_it_improves_on_preserved_candidate_order(self):
        train_rows = [self._rank_row("train", 1, 1)]
        holdout = []
        predictions = []
        for group_index in range(5):
            group = f"group-{group_index}"
            # The stable input order puts the weaker candidate first; the
            # model correctly ranks the exact higher-DPS/EHP candidate first.
            holdout.extend([self._rank_row(group, 0, 0), self._rank_row(group, 100, 100)])
            predictions.extend([0, 1])
        with mock.patch.object(trainer, "_predict", return_value=trainer.np.asarray(predictions, dtype=trainer.np.float64)):
            result = trainer.evaluate((), train_rows, holdout, hidden_size=4, seed=9)

        self.assertEqual("passed", result["status"])
        self.assertAlmostEqual(1.0, result["heldOutSpearman"])
        self.assertAlmostEqual(1.0, result["topParetoRecall"])
        self.assertAlmostEqual(-1.0, result["baselineInputOrderSpearman"])
        self.assertAlmostEqual(0.0, result["baselineInputOrderTopParetoRecall"])
        self.assertTrue(result["baselineNonRegression"])

    def test_single_candidate_group_is_unscored_and_fails_closed(self):
        train_rows = [self._rank_row("train", 1, 1)]
        holdout = []
        for group_index in range(5):
            holdout.extend([
                self._rank_row(f"group-{group_index}", 10, 10),
                self._rank_row(f"group-{group_index}", 1, 1),
            ])
        # A one-candidate group cannot establish a within-build ranking. It
        # must not receive a vacuous recall of 1.0 or disappear silently.
        holdout.append(self._rank_row("singleton-group", 5, 5))
        predictions = trainer.np.asarray([10, 1] * 5 + [5], dtype=trainer.np.float64)
        with mock.patch.object(trainer, "_predict", return_value=predictions):
            result = trainer.evaluate((), train_rows, holdout, hidden_size=4, seed=9)

        self.assertEqual(5, result["paretoScoredGroups"])
        self.assertEqual(1, result["paretoUnscoredGroups"])
        self.assertEqual("failed", result["status"])

    def test_holdout_group_outside_model_domain_fails_closed_despite_row_coverage(self):
        train_rows = [self._rank_row("train", 1, 1)]
        holdout = []
        for group_index in range(5):
            holdout.extend([
                self._rank_row(f"group-{group_index}", 10, 10),
                self._rank_row(f"group-{group_index}", 1, 1),
            ])
        unsupported = self._rank_row("unsupported-group", 5, 5)
        unsupported["feature"]["mainSkill"] = "Arc"
        holdout.append(unsupported)
        predictions = trainer.np.asarray([10, 1] * 5, dtype=trainer.np.float64)
        with mock.patch.object(trainer, "_predict", return_value=predictions):
            result = trainer.evaluate((), train_rows, holdout, hidden_size=4, seed=9)

        self.assertGreaterEqual(result["heldOutCoverage"], trainer.MIN_COVERAGE)
        self.assertEqual(6, result["heldOutSourceLineages"])
        self.assertEqual(5, result["paretoScoredGroups"])
        self.assertEqual(1, result["paretoUnscoredGroups"])
        self.assertEqual("failed", result["status"])

    def test_artifact_keeps_grouped_pareto_validation_coverage(self):
        def projected(group: str, node_id: int, delta: float) -> dict:
            raw = row("train", group, node_id, delta)
            feature = trainer.project_features(raw["features"], "CombinedDPS")
            return {
                "group": group,
                "feature": feature,
                "target": delta / 1000.0,
                "targetDelta": delta,
                "ehpDelta": delta / 10.0,
                "pointDelta": feature["numeric"][4],
            }

        train_rows = [projected("train-a", 201, 1)]
        holdout_rows = [projected("holdout-a", 201, 1), projected("holdout-a", 202, 2)]
        hidden_size = 2
        model = (
            trainer.np.zeros((trainer.FEATURE_DIMENSION, hidden_size), dtype=trainer.np.float64),
            trainer.np.zeros(hidden_size, dtype=trainer.np.float64),
            trainer.np.zeros(hidden_size, dtype=trainer.np.float64),
            trainer.np.asarray([0.0], dtype=trainer.np.float64),
            trainer.np.zeros(trainer.FEATURE_DIMENSION, dtype=trainer.np.float64),
            trainer.np.ones(trainer.FEATURE_DIMENSION, dtype=trainer.np.float64),
        )
        validation = {
            "status": "failed", "heldOutSpearman": 0.0, "topParetoRecall": 0.0,
            "baselineInputOrderSpearman": 0.0, "baselineInputOrderTopParetoRecall": 0.0,
            "baselineNonRegression": False, "baselineScoredSourceLineages": 0,
            "baselineParetoScoredGroups": 0, "baselineParetoUnscoredGroups": 1,
            "paretoScoredGroups": 0, "paretoUnscoredGroups": 1, "paretoGroupCoverage": 0.0,
            "heldOutCoverage": 1.0, "heldOutRows": 2, "supportedHeldOutRows": 2,
            "scoredSourceLineages": 0, "heldOutSourceLineages": 1,
        }
        artifact = trainer._artifact(header(1, 2, 1, 1), train_rows, holdout_rows, "CombinedDPS", model, validation, hidden_size)
        self.assertEqual(trainer.ARTIFACT_SCHEMA_VERSION, artifact["schemaVersion"])
        self.assertEqual([{
            "classId": 2, "ascendancyId": 5, "mainSkill": "Fireball", "changedNodeId": 201,
        }], artifact["domain"]["supportedMutations"])
        self.assertEqual(0, artifact["validation"]["paretoScoredGroups"])
        self.assertEqual(1, artifact["validation"]["paretoUnscoredGroups"])
        self.assertEqual(0.0, artifact["validation"]["paretoGroupCoverage"])


if __name__ == "__main__":
    unittest.main()
