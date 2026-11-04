#!/usr/bin/env python3
"""Synthetic default-ACL continuity test. Never queries the owner's connection."""
import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = r'''
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#ifndef BUILD_VERSION
#define BUILD_VERSION "A"
#endif
int main(int argc, char **argv) {@autoreleasepool {
 if(argc!=3)return 2;
 Boolean prior=true;OSStatus st=SecKeychainGetUserInteractionAllowed(&prior);if(st)return 3;
 st=SecKeychainSetUserInteractionAllowed(false);if(st)return 4;
 @try {
 NSString *op=@(argv[1]), *service=@(argv[2]);
 NSMutableDictionary *q=[@{(__bridge NSString*)kSecClass:(__bridge NSString*)kSecClassGenericPassword,(__bridge NSString*)kSecAttrService:service,(__bridge NSString*)kSecAttrAccount:@"synthetic"} mutableCopy];
 NSData *expected=[@"clouddrive-disposable-not-a-credential" dataUsingEncoding:NSUTF8StringEncoding];
 NSMutableDictionary *r=[@{@"build":@BUILD_VERSION,@"operation":op} mutableCopy];
 if([op isEqual:@"create"]){q[(__bridge NSString*)kSecValueData]=expected;q[(__bridge NSString*)kSecAttrAccessible]=(__bridge NSString*)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;st=SecItemAdd((__bridge CFDictionaryRef)q,NULL);}
 else if([op isEqual:@"read"]){q[(__bridge NSString*)kSecReturnData]=@YES;q[(__bridge NSString*)kSecMatchLimit]=(__bridge NSString*)kSecMatchLimitOne;CFTypeRef data=NULL;st=SecItemCopyMatching((__bridge CFDictionaryRef)q,&data);r[@"matchesSyntheticValue"]=@(st==0&&data&&[(__bridge NSData*)data isEqual:expected]);if(data)CFRelease(data);}
 else if([op isEqual:@"delete"]){st=SecItemDelete((__bridge CFDictionaryRef)q);}
 else return 5;
 r[@"status"]=@(st);NSData *out=[NSJSONSerialization dataWithJSONObject:r options:0 error:NULL];fwrite(out.bytes,1,out.length,stdout);fputs("\n",stdout);
 }@finally{SecKeychainSetUserInteractionAllowed(prior);}
 }return 0;}
'''


def run(args):
    return subprocess.run([str(x) for x in args], capture_output=True, text=True, timeout=30, check=True)


def main():
    baseline = json.loads((ROOT/'build/signing/stable-identity.json').read_text())
    assert baseline['mode']=='certificate'
    identity = baseline['certificateSHA1']
    temp = pathlib.Path(tempfile.mkdtemp(prefix='clouddrive-default-acl-'))
    temp.chmod(0o700)
    source = temp/'fixture.m'; source.write_text(SOURCE)
    paths = [temp/'A',temp/'B']
    service = 'local.clouddrive.synthetic.default-acl.'+str(uuid.uuid4())
    result = {'service':service,'account':'synthetic','syntheticOnly':True,'operations':[], 'defaultACL':True}
    created = False
    try:
        requirements=[]
        for version,path in zip(('A','B'),paths):
            run(['/usr/bin/clang','-Wno-deprecated-declarations',f'-DBUILD_VERSION="{version}"','-framework','Foundation','-framework','Security',source,'-o',path])
            run(['/usr/bin/codesign','--force','--sign',identity,'--identifier','local.clouddrive.synthetic.keychain-probe',path])
            run(['/usr/bin/codesign','--verify','--strict',path])
            detail=run(['/usr/bin/codesign','-d','-r-',path])
            requirement=next(line.strip().removeprefix('# ').removeprefix('designated => ') for line in (detail.stdout+detail.stderr).splitlines() if 'designated =>' in line)
            requirements.append(requirement)
        result['sameDesignatedRequirement']=requirements[0]==requirements[1]
        result['requirementSHA256']=hashlib.sha256(requirements[0].encode()).hexdigest()
        result['differentBinaryContents']=hashlib.sha256(paths[0].read_bytes()).digest()!=hashlib.sha256(paths[1].read_bytes()).digest()
        assert result['sameDesignatedRequirement'] and result['differentBinaryContents']
        def op(path,operation,label):
            output=json.loads(run([path,operation,service]).stdout)
            output['test']=label;result['operations'].append(output)
            return output
        created=op(paths[0],'create','A creates unique item with default ACL')['status']==0
        assert created, 'synthetic creation failed without interaction'
        op(paths[0],'read','unchanged A fresh process noninteractive read')
        op(paths[1],'read','changed B separate path noninteractive read')
        shutil.copy2(paths[1],temp/'replacement')
        (temp/'replacement').replace(paths[0])
        op(paths[0],'read','changed B at original A path noninteractive read')
    finally:
        if created:
            try:
                cleanup=json.loads(run([paths[0],'delete',service]).stdout)
                cleanup['test']='exact synthetic item deletion';result['operations'].append(cleanup)
                result['syntheticItemDeleted']=cleanup['status']==0
            except Exception as error:result['cleanupErrorType']=type(error).__name__
        result['fixtureDirectory']=str(temp)
        (ROOT/'build').mkdir(exist_ok=True)
        report=ROOT/'build/keychain-default-acl-report.json'
        report.write_text(json.dumps(result,indent=2))
        print(json.dumps(result,indent=2))
        print('Report:',report)


if __name__=='__main__':main()
