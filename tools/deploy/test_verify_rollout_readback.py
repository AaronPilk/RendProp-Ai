#!/usr/bin/env python3
"""Closed file-only cases; no service, credential, deployment or collector calls."""
import copy
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).with_name('verify-rollout-readback.py')
spec = importlib.util.spec_from_file_location('rollout_readback', SOURCE)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
NOW = dt.datetime(2026, 10, 17, 12, tzinfo=dt.timezone.utc)


class Readback(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rollout-readback-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.identity = {'environment':'production','account':'fixture-account','resource':'fixture-worker'}
        control = {'enabled':True,'image':'old-image','settings':{'tags':None,'logpush':False,'cpu_ms':1000},
            'bindings':[{'name':'CPU','type':'durable_object_namespace','namespace_id':'same-namespace','class_name':'SameCPU'},
                        {'name':'SERVICE_KEY','type':'secret_text'},{'name':'TRIGGER_KEY','type':'secret_text'}],
            'routes':[{'id':'route-a','pattern':'example.invalid/*','script':'fixture-worker'},
                      {'id':'route-b','pattern':'other.invalid/*','script':'fixture-worker'}],
            'secret_names':['SERVICE_KEY','TRIGGER_KEY'],'order':['first','second']}
        self.baseline = {'identity':copy.deepcopy(self.identity),'observed_at_utc':(NOW-dt.timedelta(seconds=30)).isoformat(),'control':control}
        self.actual = copy.deepcopy(self.baseline)
        self.actual['observed_at_utc'] = (NOW-dt.timedelta(seconds=5)).isoformat()
        self.actual['control']['image'] = 'new-image'
        for name in ['bindings','routes','secret_names']:self.actual['control'][name].reverse()
        self.artifact = self.root/'worker.js'
        self.artifact.write_bytes(b'export default {};\n')
        self.contract = {'schema':'rendprop-rollout-readback-v1','identity':self.identity,
            'baseline':{},'actual':{},'max_age_seconds':300,
            'inventories':[{'path':'/bindings','key':'name'},{'path':'/routes','key':'id'},{'path':'/secret_names','key':'$value'}],
            'changes':[{'path':'/image','old':'old-image','new':'new-image'}],
            'artifacts':{'worker.js':self.sha(self.artifact)}}

    @staticmethod
    def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

    def save(self):
        for name, data in [('baseline',self.baseline),('actual',self.actual)]:
            path=self.root/(name+'.json');path.write_text(json.dumps(data))
            self.contract[name]={'path':path.name,'sha256':self.sha(path)}
        path=self.root/'contract.json';path.write_text(json.dumps(self.contract))
        return path,self.sha(path)

    def run_gate(self):
        path,digest=self.save()
        return gate.verify(path,digest,now=NOW)

    def refuses(self, code):
        with self.assertRaises(gate.Refusal) as caught:self.run_gate()
        self.assertEqual(caught.exception.code,code)
        return caught.exception

    def test_exact_with_explicit_keyed_inventory_order(self):
        result=self.run_gate();self.assertEqual(result['status'],'HISTORICAL_REPLAY')
        self.assertEqual(result['expectedControlSHA256'],result['actualControlSHA256'])
        self.assertTrue(self.actual['control']['enabled'])

    def test_account_mismatch(self):
        self.actual['identity']['account']='wrong-account';self.refuses('identity_mismatch')
    def test_environment_mismatch(self):
        self.actual['identity']['environment']='staging';self.refuses('identity_mismatch')
    def test_resource_mismatch(self):
        self.actual['identity']['resource']='other-worker';self.refuses('identity_mismatch')
    def test_stale_baseline(self):
        self.baseline['observed_at_utc']=(NOW-dt.timedelta(seconds=301)).isoformat();self.refuses('snapshot_not_fresh')
    def test_future_baseline(self):
        self.baseline['observed_at_utc']=(NOW+dt.timedelta(seconds=1)).isoformat();self.refuses('snapshot_not_fresh')
    def test_stale_readback(self):
        self.actual['observed_at_utc']=(NOW-dt.timedelta(seconds=301)).isoformat();self.refuses('snapshot_not_fresh')
    def test_readback_before_baseline(self):
        self.actual['observed_at_utc']=(NOW-dt.timedelta(seconds=31)).isoformat();self.refuses('readback_precedes_baseline')
    def test_naive_timestamp(self):
        self.baseline['observed_at_utc']='2026-10-17T12:00:00';self.refuses('snapshot_not_fresh')
    def test_age_boolean_rejected(self):
        self.contract['max_age_seconds']=True;self.refuses('age_policy')
    def test_age_cannot_exceed_fixed_cap(self):
        self.contract['max_age_seconds']=301;self.refuses('age_policy')
    def test_extra_control_key(self):
        self.actual['control']['unreviewed']=True;self.refuses('control_document_drift')
    def test_missing_control_key(self):
        del self.actual['control']['settings']['tags'];self.refuses('control_document_drift')
    def test_enabled_flag_drift(self):
        self.actual['control']['enabled']=False;self.refuses('control_document_drift')
    def test_boolean_not_number(self):
        self.actual['control']['enabled']=1;self.refuses('control_document_drift')
    def test_null_not_empty_array(self):
        self.actual['control']['settings']['tags']=[];self.refuses('control_document_drift')
    def test_binding_namespace_drift(self):
        row=next(r for r in self.actual['control']['bindings'] if r['name']=='CPU');row['namespace_id']='new-namespace';self.refuses('control_document_drift')
    def test_binding_class_drift(self):
        row=next(r for r in self.actual['control']['bindings'] if r['name']=='CPU');row['class_name']='OtherCPU';self.refuses('control_document_drift')
    def test_binding_type_drift(self):
        row=next(r for r in self.actual['control']['bindings'] if r['name']=='CPU');row['type']='plain_text';self.refuses('control_document_drift')
    def test_route_id_drift(self):
        self.actual['control']['routes'][0]['id']='new-id';self.refuses('control_document_drift')
    def test_extra_secret_name_and_binding(self):
        self.actual['control']['secret_names'].append('EXTRA_KEY')
        self.actual['control']['bindings'].append({'name':'EXTRA_KEY','type':'secret_text'});self.refuses('control_document_drift')
    def test_duplicate_inventory_identity(self):
        self.actual['control']['bindings'].append(copy.deepcopy(self.actual['control']['bindings'][0]));self.refuses('inventory_duplicate')
    def test_duplicate_baseline_not_hidden_by_replacement(self):
        self.baseline['control']['routes'].append(copy.deepcopy(self.baseline['control']['routes'][0]));self.refuses('inventory_duplicate')
    def test_inventory_key_missing(self):
        row=next(r for r in self.actual['control']['bindings'] if r['name']=='CPU');del row['name'];self.refuses('inventory_key_missing')
    def test_inventory_key_wrong_type(self):
        row=next(r for r in self.actual['control']['bindings'] if r['name']=='CPU');row['name']=False;self.refuses('inventory_key_type')
    def test_inventory_array_missing(self):
        del self.actual['control']['routes'];self.refuses('pointer_missing')
    def test_inventory_wrong_container(self):
        self.actual['control']['routes']={};self.refuses('inventory_not_array')
    def test_array_order_remains_meaningful_without_inventory(self):
        self.actual['control']['order'].reverse();self.refuses('control_document_drift')
    def test_duplicate_inventory_path(self):
        self.contract['inventories'].append(copy.deepcopy(self.contract['inventories'][0]));self.refuses('duplicate_pointer')
    def test_wildcard_not_supported(self):
        self.contract['changes'][0]['path']='/*';self.refuses('invalid_pointer')
    def test_change_requires_existing_path(self):
        self.contract['changes'][0]['path']='/new';self.refuses('pointer_missing')
    def test_exact_old_value_required(self):
        self.contract['changes'][0]['old']='guessed-old';self.refuses('change_old_mismatch')
    def test_noop_is_not_an_exception(self):
        self.contract['changes'][0]['new']='old-image';self.refuses('no_op_change')
    def test_overlapping_changes_refused(self):
        self.contract['changes']=[{'path':'/settings','old':{},'new':{}},{'path':'/settings/tags','old':None,'new':[]}];self.refuses('overlapping_pointers')
    def test_duplicate_changes_refused(self):
        self.contract['changes'].append(copy.deepcopy(self.contract['changes'][0]));self.refuses('duplicate_pointer')
    def test_unknown_contract_keys_not_ignore_list(self):
        self.contract['ignored_keys']=['enabled'];self.refuses('contract_shape')
    def test_secret_binding_may_contain_names_only(self):
        row=next(r for r in self.actual['control']['bindings'] if r['type']=='secret_text');row['value']='fixture-value';self.refuses('secret_binding_value')
    def test_secret_like_plain_text_binding_refused(self):
        self.actual['control']['bindings'].append({'name':'API_KEY','type':'plain_text','text':'fixture-value'});self.refuses('secret_binding_type')
    def test_credential_value_field_refused(self):
        self.actual['control']['password']='fixture-value';self.refuses('credential_value_field')
    def test_capability_string_refused(self):
        self.actual['control']['settings']['note']='Bearer'+' '+'fixture-value';self.refuses('capability_value')
    def test_duplicate_secret_names_refused(self):
        self.actual['control']['secret_names'].append('SERVICE_KEY');self.refuses('secret_names_shape')
    def test_tampered_artifact_refused(self):
        self.artifact.write_bytes(b'changed\n');self.refuses('artifact_hash_mismatch')
    def test_artifact_symlink_refused(self):
        other=self.root/'other.js';other.write_bytes(self.artifact.read_bytes());self.artifact.unlink();self.artifact.symlink_to(other);self.refuses('file_open_refused')
    def test_artifact_directory_refused(self):
        self.artifact.unlink();self.artifact.mkdir();self.refuses('file_not_regular_or_too_large')
    def test_contract_digest_required(self):
        path,_=self.save()
        with self.assertRaises(gate.Refusal) as caught:gate.verify(path,'0'*64,now=NOW)
        self.assertEqual(caught.exception.code,'contract_hash_mismatch')
    def test_snapshot_digest_required(self):
        path,digest=self.save();(self.root/'actual.json').write_text('{}')
        with self.assertRaises(gate.Refusal) as caught:gate.verify(path,digest,now=NOW)
        self.assertEqual(caught.exception.code,'document_hash_mismatch')
    def test_duplicate_json_key_refused(self):
        path,_=self.save();actual=self.root/'actual.json';actual.write_text('{"identity":{},"identity":{}}')
        self.contract['actual']['sha256']=self.sha(actual);path.write_text(json.dumps(self.contract))
        with self.assertRaises(gate.Refusal) as caught:gate.verify(path,self.sha(path),now=NOW)
        self.assertEqual(caught.exception.code,'duplicate_json_key')
    def test_nonfinite_refused(self):
        self.actual['control']['number']=float('nan');self.refuses('nonfinite_json')
    def test_unknown_snapshot_key_refused(self):
        self.actual['ignored']='not-ignored';self.refuses('snapshot_shape')
    def test_report_contains_paths_and_hashes_not_values(self):
        private='private'+'-compared-value';self.actual['control']['settings']['note']=private
        error=self.refuses('control_document_drift');report=json.dumps(error.differences)
        self.assertNotIn(private,report);self.assertIn('/settings/note',report)
    def test_json_pointer_escapes(self):
        self.baseline['control']['annotations']={'workers/tag':'old-tag'}
        self.actual['control']['annotations']={'workers/tag':'new-tag'}
        self.contract['changes'].append({'path':'/annotations/workers~1tag','old':'old-tag','new':'new-tag'})
        self.run_gate()
    def test_pointer_capability_cannot_echo(self):
        private='sk_'+'live_'+'x'*20
        self.contract['changes'][0]['path']='/settings/'+private
        error=self.refuses('invalid_pointer');self.assertNotIn(private,json.dumps(error.paths))
    def test_pointer_space_refused_before_echo(self):
        self.contract['changes'][0]['path']='/settings/private field'
        error=self.refuses('invalid_pointer');self.assertEqual(error.paths,[])
    def test_capability_object_key_cannot_echo(self):
        private='ey'+'J'+'x'*16+'.'+'y'*16+'.'+'z'*16
        self.actual['control'][private]=True
        error=self.refuses('unsafe_field_name');self.assertNotIn(private,json.dumps(error.paths))
    def test_json_pointer_tilde_escape(self):
        self.baseline['control']['annotations']={'a~b':'old-tag'}
        self.actual['control']['annotations']={'a~b':'new-tag'}
        self.contract['changes'].append({'path':'/annotations/a~0b','old':'old-tag','new':'new-tag'})
        self.run_gate()
    def test_cli_current_utc_and_safe_output(self):
        now=dt.datetime.now(dt.timezone.utc)
        self.baseline['observed_at_utc']=(now-dt.timedelta(seconds=30)).isoformat()
        self.actual['observed_at_utc']=(now-dt.timedelta(seconds=5)).isoformat()
        path,digest=self.save();r=subprocess.run([sys.executable,str(SOURCE),'--contract',str(path),'--contract-sha256',digest],capture_output=True,timeout=10)
        self.assertEqual(r.returncode,0,r.stderr.decode());value=json.loads(r.stdout);self.assertEqual(value['status'],'VERIFIED_FILE_ONLY')
        self.assertNotIn('fixture-account',r.stdout.decode());self.assertNotIn('new-image',r.stdout.decode())
    def test_cli_historical_capture_does_not_become_fresh(self):
        self.baseline['observed_at_utc']='2000-01-01T00:00:00+00:00';path,digest=self.save()
        r=subprocess.run([sys.executable,str(SOURCE),'--contract',str(path),'--contract-sha256',digest],capture_output=True,timeout=10)
        self.assertEqual(r.returncode,2);self.assertEqual(json.loads(r.stdout)['code'],'snapshot_not_fresh')


if __name__=='__main__':unittest.main(verbosity=2)
