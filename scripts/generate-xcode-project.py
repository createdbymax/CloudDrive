#!/usr/bin/env python3
"""Generate the checked-in native Xcode project using only Python's standard library."""
import hashlib
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJECT = ROOT/'CloudDrive.xcodeproj'
objects = {}


def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def add(object_name, isa, **values):
    key = ident(object_name)
    objects[key] = dict(isa=isa, **values)
    return key


def config_list(name, settings):
    configs = []
    for mode in ['Debug', 'Release']:
        values = dict(settings)
        values.update(SWIFT_OPTIMIZATION_LEVEL='-Onone' if mode == 'Debug' else '-O',
                      DEBUG_INFORMATION_FORMAT='dwarf' if mode == 'Debug' else 'dwarf-with-dsym')
        if mode == 'Debug':
            values.update(ENABLE_TESTABILITY='YES', SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG')
        configs.append(add(name+mode, 'XCBuildConfiguration', buildSettings=values, name=mode))
    return add(name+'configs', 'XCConfigurationList', buildConfigurations=configs,
               defaultConfigurationIsVisible=0, defaultConfigurationName='Release')


app = ident('app-target')
helper = ident('helper-target')
products = []
groups = []
phases = {}
for name, folder, product_type, explicit_type, product_path in [
    ('app', 'CloudDrive', 'com.apple.product-type.application', 'wrapper.application', 'CloudDrive.app'),
    ('helper', 'CloudDriveHelper', 'com.apple.product-type.tool', 'compiled.mach-o.executable', 'CloudDriveHelper')]:
    refs, builds = [], []
    for source in sorted((ROOT/'Sources'/folder).glob('*.swift')):
        ref = add(str(source.relative_to(ROOT)), 'PBXFileReference', lastKnownFileType='sourcecode.swift',
                  path=source.name, sourceTree='<group>')
        refs.append(ref)
        builds.append(add('build:'+str(source.relative_to(ROOT)), 'PBXBuildFile', fileRef=ref))
    groups.append(add(name+'sources', 'PBXGroup', children=refs, path='Sources/'+folder, sourceTree='<group>'))
    phases[name] = add(name+'compile', 'PBXSourcesBuildPhase', buildActionMask=2147483647,
                       files=builds, runOnlyForDeploymentPostprocessing=0)
    products.append(add(name+'product', 'PBXFileReference', explicitFileType=explicit_type,
                        path=product_path, sourceTree='BUILT_PRODUCTS_DIR'))


def shell(name, script):
    return add(name, 'PBXShellScriptBuildPhase', buildActionMask=2147483647, files=[],
               inputPaths=[], outputPaths=[], runOnlyForDeploymentPostprocessing=0,
               alwaysOutOfDate=1, name=name, shellPath='/bin/sh', shellScript=script)


preflight = shell('Check signing and inactive app', '''set -eu
cd "$SRCROOT"
python3 scripts/package-app.py --preflight "$TARGET_BUILD_DIR/$WRAPPER_NAME"
backend="${CLOUDDRIVE_BACKEND:-$SRCROOT/build/backend/rclone}"
if [ ! -x "$backend" ]; then
  echo "error: Build the backend once: python3 scripts/build-rclone-allocation.py"
  exit 1
fi
''')
package = shell('Package backend, helper and stable signature', '''set -eu
cd "$SRCROOT"
python3 scripts/package-app.py "$TARGET_BUILD_DIR/$WRAPPER_NAME" "$BUILT_PRODUCTS_DIR" "${CLOUDDRIVE_BACKEND:-$SRCROOT/build/backend/rclone}"
''')
# Seal the bundle only after Xcode has finished generating its Info.plist.
objects[package]['inputPaths'] = ['$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)', '$(TARGET_BUILD_DIR)/$(EXECUTABLE_PATH)']
proxy = add('helper-proxy', 'PBXContainerItemProxy', containerPortal=ident('project'), proxyType=1,
            remoteGlobalIDString=helper, remoteInfo='CloudDriveHelper')
dep = add('helper-dependency', 'PBXTargetDependency', target=helper, targetProxy=proxy)
common = dict(ALWAYS_SEARCH_USER_PATHS='NO', ARCHS='arm64', ONLY_ACTIVE_ARCH='YES', ENABLE_DEBUG_DYLIB='NO', SWIFT_VERSION='5.0', MACOSX_DEPLOYMENT_TARGET='14.0', SDKROOT='macosx',
              CODE_SIGNING_ALLOWED='NO', ENABLE_USER_SCRIPT_SANDBOXING='NO',
              CLOUDDRIVE_ADHOC_ONLY='0', CLOUDDRIVE_SIGN_IDENTITY='',
              CLOUDDRIVE_BACKEND='$(SRCROOT)/build/backend/rclone',
              CLOUDDRIVE_SPARKLE_FEED_URL='', CLOUDDRIVE_SPARKLE_PUBLIC_KEY='', CLOUDDRIVE_RELEASE='0',
              CLOUDDRIVE_APP_VERSION='0.5.5', CLOUDDRIVE_APP_BUILD='14',
              PRODUCT_NAME='$(TARGET_NAME)', SWIFT_EMIT_LOC_STRINGS='NO')
app_settings = dict(common, PRODUCT_BUNDLE_IDENTIFIER='local.bucketdrive.app',
                    GENERATE_INFOPLIST_FILE='YES', INFOPLIST_KEY_CFBundleDisplayName='CloudDrive',
                    MARKETING_VERSION='0.5.5', CURRENT_PROJECT_VERSION='14',
                    ENABLE_APP_SANDBOX='NO', COMBINE_HIDPI_IMAGES='YES',
                    LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/../Frameworks'])
sparkle_package = add('sparkle-package', 'XCRemoteSwiftPackageReference', repositoryURL='https://github.com/sparkle-project/Sparkle', requirement={'kind': 'exactVersion', 'version': '2.10.1'})
sparkle_product = add('sparkle-product', 'XCSwiftPackageProductDependency', package=sparkle_package, productName='Sparkle')
sparkle_build = add('sparkle-link', 'PBXBuildFile', productRef=sparkle_product)
sparkle_link = add('app-frameworks', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[sparkle_build], runOnlyForDeploymentPostprocessing=0)
add('app-target', 'PBXNativeTarget' , buildConfigurationList=config_list('app', app_settings),
    buildPhases=[preflight, phases['app'], sparkle_link, package], packageProductDependencies=[sparkle_product], buildRules=[], dependencies=[dep],
    name='CloudDrive', productName='CloudDrive', productReference=products[0],
    productType='com.apple.product-type.application')
add('helper-target', 'PBXNativeTarget', buildConfigurationList=config_list('helper', common),
    buildPhases=[phases['helper']], buildRules=[], dependencies=[], name='CloudDriveHelper',
    productName='CloudDriveHelper', productReference=products[1], productType='com.apple.product-type.tool')
product_group = add('products', 'PBXGroup', children=products, name='Products', sourceTree='<group>')
readme = add('readme', 'PBXFileReference', lastKnownFileType='net.daringfireball.markdown', path='README.md', sourceTree='<group>')
main = add('main-group', 'PBXGroup', children=groups+[readme, product_group], sourceTree='<group>')
add('project', 'PBXProject', attributes={'BuildIndependentTargetsInParallel': 'YES', 'LastUpgradeCheck': '2700'},
    buildConfigurationList=config_list('project', {}), compatibilityVersion='Xcode 14.0',
    developmentRegion='en', hasScannedForEncodings=0, knownRegions=['en', 'Base'],
    packageReferences=[sparkle_package], mainGroup=main, productRefGroup=product_group, projectDirPath='', projectRoot='', targets=[app, helper])


def encode(value):
    if isinstance(value, dict):
        return '{\n'+''.join(f'{json.dumps(str(k))} = {encode(v)};\n' for k,v in value.items())+'}'
    if isinstance(value, list):
        return '('+', '.join(encode(v) for v in value)+')'
    return str(value) if isinstance(value, int) else json.dumps(value)


PROJECT.mkdir(exist_ok=True)
(PROJECT/'project.pbxproj').write_text('// !$*UTF8*$!\n'+encode(dict(archiveVersion=1, classes={}, objectVersion=56,
                                                                objects=objects, rootObject=ident('project')))+'\n')
schemes = PROJECT/'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="CloudDrive.app" BlueprintName="CloudDrive" ReferencedContainer="container:CloudDrive.xcodeproj"/>'
(schemes/'CloudDrive.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="NO" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(PROJECT)
