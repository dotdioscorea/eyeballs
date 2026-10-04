#!/usr/bin/env python3
"""Prepare Requota's editable App Store draft. Never submits or releases an app."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import requests

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('apple_connect', ROOT / 'scripts/apple-connect.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['metadata', 'screenshots', 'pricing', 'availability', 'select-build', 'verify'])
    parser.add_argument('--config', type=Path, default=ROOT / '.release/apple.json')
    parser.add_argument('--app-id', default='6818509879')
    parser.add_argument('--build')
    parser.add_argument('--apply', action='store_true', help='Write the editable draft; default is read-only')
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    def request(method, path, **kwargs):
        # Refresh the short-lived JWT for long screenshot uploads; never log it.
        return module.AppleConnect(config).request(method, path, **kwargs)
    app = request('GET', '/v1/apps/' + args.app_id)['data']
    if app['attributes']['bundleId'] != 'com.dotdioscorea.eyeballs':
        raise RuntimeError('Selected app is not Requota')
    listing = json.loads((ROOT / 'docs/app-store/listing-en-GB.json').read_text())
    metadata = listing['metadata']
    versions = request('GET', f'/v1/apps/{args.app_id}/appStoreVersions')['data']
    matches = [v for v in versions if v['attributes']['versionString'] == listing['appVersion'] and v['attributes']['platform'] == 'IOS']
    if len(matches) != 1:
        raise RuntimeError('Expected one matching iOS version')
    version = matches[0]
    state = version['attributes']['appStoreState']
    if args.apply and state not in ['PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED']:
        raise RuntimeError('Version is not an editable, unsubmitted draft')
    vid = version['id']
    locales = request('GET', f'/v1/appStoreVersions/{vid}/appStoreVersionLocalizations')['data']
    locale = next(l for l in locales if l['attributes']['locale'] == listing['locale'])
    lid = locale['id']
    def patch(kind, identifier, attributes=None, relationships=None):
        data = {'type': kind, 'id': identifier}
        if attributes is not None: data['attributes'] = attributes
        if relationships is not None: data['relationships'] = relationships
        return request('PATCH', f'/v1/{kind}/{identifier}', json={'data': data})
    if args.action == 'metadata':
        infos = request('GET', f'/v1/apps/{args.app_id}/appInfos')['data']
        info = next(i for i in infos if i['attributes']['appStoreState'] == state)
        ilocales = request('GET', f"/v1/appInfos/{info['id']}/appInfoLocalizations")['data']
        ilocale = next(l for l in ilocales if l['attributes']['locale'] == listing['locale'])
        age = request('GET', f"/v1/appInfos/{info['id']}/ageRatingDeclaration")['data']
        review = request('GET', f'/v1/appStoreVersions/{vid}/appStoreReviewDetail')['data']
        review_notes = (ROOT / 'docs/app-store/review-notes.txt').read_text().strip()
        if len(review_notes) > 4000: raise RuntimeError('Review notes exceed 4000 characters')
        if not args.apply:
            print('Draft ready: listing, categories, age questionnaire, reviewer Demo instructions and manual release.')
            return
        patch('appInfoLocalizations', ilocale['id'], {'name': metadata['name'], 'subtitle': metadata['subtitle'], 'privacyPolicyUrl': metadata['privacyPolicyURL']})
        patch('appStoreVersionLocalizations', lid, {'description': metadata['description'], 'keywords': metadata['keywords'], 'promotionalText': metadata['promotionalText'], 'supportUrl': metadata['supportURL']})
        patch('appStoreVersions', vid, {'copyright': metadata['copyright'], 'releaseType': 'MANUAL'})
        patch('appInfos', info['id'], relationships={k: {'data': {'type': 'appCategories', 'id': v}} for k, v in [('primaryCategory','UTILITIES'), ('secondaryCategory','PRODUCTIVITY')]})
        # Answers describe Requota itself, not the capabilities of external providers.
        answers = {k: False if isinstance(v, bool) or k in ['advertising','gambling','healthOrWellnessTopics','lootBox','messagingAndChat','parentalControls','ageAssurance','socialMedia','socialMediaAgeRestricted','unrestrictedWebAccess','userGeneratedContent'] else 'NONE' for k, v in age['attributes'].items() if k not in ['kidsAgeBand','ageRatingOverride','ageRatingOverrideV2','koreaAgeRatingOverride','gracRatingClassificationNumber','developerAgeRatingInfoUrl']}
        patch('ageRatingDeclarations', age['id'], answers)
        previous = request('GET', f'/v1/apps/{args.app_id}/betaAppReviewDetail')['data']['attributes']
        contacts = {k: previous[k] for k in ['contactFirstName','contactLastName','contactPhone','contactEmail'] if previous.get(k)}
        if len(contacts) != 4: raise RuntimeError('Existing authorized reviewer contact details are incomplete')
        attrs = dict(contacts, demoAccountRequired=False, notes=review_notes)
        if review: patch('appStoreReviewDetails', review['id'], attrs)
        else: request('POST', '/v1/appStoreReviewDetails', json={'data': {'type': 'appStoreReviewDetails', 'attributes': attrs, 'relationships': {'appStoreVersion': {'data': {'type':'appStoreVersions','id':vid}}}}})
        print('Saved listing, categories, age questionnaire, reviewer instructions and manual release. No submission created.')
    elif args.action == 'screenshots':
        groups = [('APP_IPHONE_67', listing['screenshots']), ('APP_IPAD_PRO_3GEN_129', listing['ipadScreenshots'])]
        sets = request('GET', f'/v1/appStoreVersionLocalizations/{lid}/appScreenshotSets')['data']
        for display, shots in groups:
            if not args.apply:
                print(display + ': ' + str(len(shots)) + ' screenshots ready')
                continue
            match = next((s for s in sets if s['attributes']['screenshotDisplayType'] == display), None)
            if not match:
                match = request('POST','/v1/appScreenshotSets',json={'data':{'type':'appScreenshotSets','attributes':{'screenshotDisplayType':display},'relationships':{'appStoreVersionLocalization':{'data':{'type':'appStoreVersionLocalizations','id':lid}}}}})['data']
            sid = match['id']
            existing = request('GET', f'/v1/appScreenshotSets/{sid}/appScreenshots')['data']
            identifiers = []
            for shot in shots:
                path = ROOT / 'docs/app-store' / shot['asset']
                data = path.read_bytes()
                checksum = hashlib.md5(data).hexdigest()
                found = next((s for s in existing if s['attributes'].get('sourceFileChecksum') == checksum), None)
                if not found:
                    # Retry a reserved upload from this renderer without duplicating assets.
                    name = path.stem + '-' + checksum[:12] + '.png'
                    found = next((s for s in existing if s['attributes'].get('fileName') == name), None)
                    if not found:
                        found = request('POST','/v1/appScreenshots',json={'data':{'type':'appScreenshots','attributes':{'fileName':name,'fileSize':len(data)},'relationships':{'appScreenshotSet':{'data':{'type':'appScreenshotSets','id':sid}}}}})['data']
                    for op in found['attributes'].get('uploadOperations', []):
                        response = requests.request(op['method'], op['url'], headers={h['name']: h['value'] for h in op.get('requestHeaders',[])}, data=data[op['offset']:op['offset'] + op['length']], timeout=90, allow_redirects=False)
                        if not response.ok: raise RuntimeError('Screenshot upload returned HTTP ' + str(response.status_code))
                    patch('appScreenshots', found['id'], {'uploaded':True,'sourceFileChecksum':checksum})
                identifiers.append({'type':'appScreenshots','id':found['id']})
                print('Uploaded ' + shot['asset'], flush=True)
            if any(s['id'] not in {i['id'] for i in identifiers} for s in existing):
                raise RuntimeError('Unmanaged screenshots exist; inspect before changing their order')
            request('PATCH',f'/v1/appScreenshotSets/{sid}/relationships/appScreenshots',json={'data':identifiers})
    elif args.action == 'pricing':
        schedule = request('GET', f'/v1/apps/{args.app_id}/appPriceSchedule')['data']
        try:
            existing = request('GET', f"/v1/appPriceSchedules/{schedule['id']}/manualPrices", params={'include':'appPricePoint','limit':200})
        except RuntimeError as error:
            if 'HTTP 404 ' not in str(error): raise
            existing = {'data':[]}
        if existing['data']:
            points = [p for p in existing.get('included',[]) if p['type'] == 'appPricePoints']
            if not points or any(float(p['attributes']['customerPrice']) != 0 for p in points):
                raise RuntimeError('An existing price requires inspection before changing it')
            print('Free pricing is already configured')
            return
        points = request('GET', f'/v1/apps/{args.app_id}/appPricePoints', params={'filter[territory]':'USA','limit':200})['data']
        free = next(p for p in points if float(p['attributes']['customerPrice']) == 0)
        if args.apply:
            request('POST','/v1/appPriceSchedules',json={
                'data':{'type':'appPriceSchedules','relationships':{
                    'app':{'data':{'type':'apps','id':args.app_id}},
                    'baseTerritory':{'data':{'type':'territories','id':'USA'}},
                    'manualPrices':{'data':[{'type':'appPrices','id':'${free}'}]}}},
                'included':[{'type':'appPrices','id':'${free}','attributes':{'startDate':None,'endDate':None},
                             'relationships':{'appPricePoint':{'data':{'type':'appPricePoints','id':free['id']}}}}]})
        print(('Configured' if args.apply else 'Ready to configure') + ' free pricing')
    elif args.action == 'availability':
        try:
            existing = request('GET', f'/v1/apps/{args.app_id}/appAvailabilityV2')['data']
        except RuntimeError as error:
            if 'HTTP 404 ' not in str(error): raise
            existing = None
        if existing:
            print('Availability already exists; inspect it rather than replacing it')
            return
        territories = request('GET','/v1/territories',params={'limit':200})
        if territories.get('links',{}).get('next'): raise RuntimeError('Territories exceed one page')
        included = [{'type':'territoryAvailabilities','id':'${' + t['id'] + '}',
                     'attributes':{'available':True,'preOrderEnabled':False},
                     'relationships':{'territory':{'data':{'type':'territories','id':t['id']}}}} for t in territories['data']]
        if args.apply:
            request('POST','/v2/appAvailabilities',json={
                'data':{'type':'appAvailabilities','attributes':{'availableInNewTerritories':True},
                        'relationships':{'app':{'data':{'type':'apps','id':args.app_id}},
                                         'territoryAvailabilities':{'data':[{'type':t['type'],'id':t['id']} for t in included]}}},
                'included':included})
        print(('Configured' if args.apply else 'Ready to configure') + ' availability in ' + str(len(included)) + ' territories, including future territories')
    elif args.action == 'select-build':
        if not args.build: raise RuntimeError('Provide --build')
        matches = request('GET','/v1/builds',params={'filter[app]':args.app_id,'filter[version]':args.build})['data']
        if len(matches) != 1 or matches[0]['attributes']['processingState'] != 'VALID': raise RuntimeError('Build is not uniquely available and valid')
        if args.apply: patch('appStoreVersions',vid,relationships={'build':{'data':{'type':'builds','id':matches[0]['id']}}})
        print(('Selected ' if args.apply else 'Ready to select ') + 'build ' + args.build)
    elif args.action == 'verify':
        sets = request('GET',f'/v1/appStoreVersionLocalizations/{lid}/appScreenshotSets')['data']
        results = []
        for item in sets:
            screenshots = request('GET',f"/v1/appScreenshotSets/{item['id']}/appScreenshots")['data']
            results.append({'display':item['attributes']['screenshotDisplayType'],'count':len(screenshots),'states':[s['attributes']['assetDeliveryState'] for s in screenshots]})
        build = request('GET',f'/v1/appStoreVersions/{vid}/build')['data']
        print(json.dumps({'state':state,'releaseType':version['attributes']['releaseType'],'build':build['attributes']['version'] if build else None,'descriptionMatches':locale['attributes']['description']==metadata['description'],'screenshots':results},indent=2))

if __name__ == '__main__':
    main()
