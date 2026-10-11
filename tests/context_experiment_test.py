import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('experiment', Path(__file__).parents[1]/'scripts/context_experiment.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ContextExperimentTests(unittest.TestCase):
    def test_independent_policy_priority(self):
        cases = [({'input_budget':100,'required_tokens':101,'candidate_tokens':200,'older_reference':'known'},'review'),
                 ({'input_budget':100,'required_tokens':20,'candidate_tokens':200,'older_reference':'known'},'retrieve'),
                 ({'input_budget':100,'required_tokens':20,'candidate_tokens':101,'older_reference':'none'},'compact'),
                 ({'input_budget':100,'required_tokens':20,'candidate_tokens':100,'older_reference':'none'},'keep')]
        for state, expected in cases: self.assertEqual(module.reference_policy(state), expected)

    def test_label_not_sent_and_options_permuted(self):
        calls=[]
        class Judge:
            def decide(self,state,questions):
                calls.append((state,questions)); choice=module.reference_policy(state)
                return {'answers':{'context':{'choice':choice,'probabilities':{k:float(k==choice) for k in module.ACTIONS}}}}
        result=module.experiment('jev',Judge(),2)
        self.assertEqual(result['summary']['correct'],4)
        self.assertEqual(result['summary']['order_disagreements'],0)
        self.assertNotIn('expected',calls[0][0])
        self.assertNotIn('id',calls[0][0])
        self.assertEqual(list(calls[0][1]['context']['criteria']),list(reversed(calls[1][1]['context']['criteria'])))

    def test_provider_failure_stops_calls_without_invented_accuracy(self):
        class Judge:
            calls=0
            def decide(self,*args): self.calls+=1; raise OSError('private transport detail')
        judge=Judge(); result=module.experiment('jev',judge)
        self.assertEqual(judge.calls,1)
        self.assertEqual(result['summary']['completed'],0)
        self.assertIsNone(result['summary']['median_seconds'])
        self.assertNotIn('private transport detail',str(result))

    def test_uncalibrated_support_and_invalid_distributions(self):
        result={'answers':{'context':{'choice':'keep','probabilities':[.4,.2,.2,.2]}}}
        self.assertFalse(module.normalize(result,list(module.ACTIONS))['accepted'])
        result['answers']['context']['probabilities']=[True,0,0,0]
        with self.assertRaises(ValueError): module.normalize(result,list(module.ACTIONS))

if __name__=='__main__': unittest.main()
