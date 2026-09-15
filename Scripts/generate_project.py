#!/usr/bin/env python3
"""Generate the thin Xcode host deterministically; core implementation stays in SwiftPM."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parent.parent
objects = {}
def ident(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def add(name, body):
    key = ident(name); objects[key] = body; return key
def ref(name): return ident(name)

add('appfile', 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = App/main.swift; sourceTree = SOURCE_ROOT;')
add('testfile', 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = UITests/AirMarkUITests.swift; sourceTree = SOURCE_ROOT;')
add('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = AirMark.app; sourceTree = BUILT_PRODUCTS_DIR;')
add('testproduct', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = AirMarkUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
add('appbuild', f'isa = PBXBuildFile; fileRef = {ref("appfile")};')
add('testbuild', f'isa = PBXBuildFile; fileRef = {ref("testfile")};')
add('coreproduct', f'isa = XCSwiftPackageProductDependency; productName = AirMarkCore;')
add('editorproduct', f'isa = XCSwiftPackageProductDependency; productName = AirMarkEditor;')
add('corebuild', f'isa = PBXBuildFile; productRef = {ref("coreproduct")};')
add('editorbuild', f'isa = PBXBuildFile; productRef = {ref("editorproduct")};')
add('package', 'isa = XCLocalSwiftPackageReference; relativePath = .;')
add('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({ref("appbuild")},); runOnlyForDeploymentPostprocessing = 0;')
add('testsources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({ref("testbuild")},); runOnlyForDeploymentPostprocessing = 0;')
add('frameworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({ref("corebuild")},{ref("editorbuild")},); runOnlyForDeploymentPostprocessing = 0;')
add('resources', 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
add('products', f'isa = PBXGroup; children = ({ref("product")},{ref("testproduct")},); name = Products; sourceTree = "<group>";')
add('main', f'isa = PBXGroup; children = ({ref("appfile")},{ref("testfile")},{ref("products")},); sourceTree = "<group>";')
for mode in ['Debug', 'Release']:
    add('project'+mode, f'isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 26.0; ARCHS = arm64; SWIFT_VERSION = 6.0; CLANG_ENABLE_MODULES = YES; SWIFT_STRICT_CONCURRENCY = complete; }};')
    opt = '-Onone' if mode == 'Debug' else '-O'
    add('app'+mode, f'isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ PRODUCT_NAME = AirMark; PRODUCT_BUNDLE_IDENTIFIER = com.airmark.AirMark; INFOPLIST_FILE = App/Info.plist; GENERATE_INFOPLIST_FILE = NO; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; ENABLE_APP_SANDBOX = NO; ENABLE_HARDENED_RUNTIME = YES; SWIFT_OPTIMIZATION_LEVEL = "{opt}"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) {"DEBUG" if mode == "Debug" else ""}"; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks"; }};')
    add('test'+mode, f'isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ PRODUCT_NAME = AirMarkUITests; PRODUCT_BUNDLE_IDENTIFIER = com.airmark.AirMarkUITests; GENERATE_INFOPLIST_FILE = YES; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; TEST_TARGET_NAME = AirMark; }};')
for kind in ['project','app','test']:
    add(kind+'configs', f'isa = XCConfigurationList; buildConfigurations = ({ref(kind+"Debug")},{ref(kind+"Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('proxy', f'isa = PBXContainerItemProxy; containerPortal = {ref("project")}; proxyType = 1; remoteGlobalIDString = {ref("app")}; remoteInfo = AirMark;')
add('dependency', f'isa = PBXTargetDependency; target = {ref("app")}; targetProxy = {ref("proxy")};')
add('app', f'isa = PBXNativeTarget; buildConfigurationList = {ref("appconfigs")}; buildPhases = ({ref("sources")},{ref("frameworks")},{ref("resources")},); buildRules = (); dependencies = (); name = AirMark; packageProductDependencies = ({ref("coreproduct")},{ref("editorproduct")},); productName = AirMark; productReference = {ref("product")}; productType = "com.apple.product-type.application";')
add('test', f'isa = PBXNativeTarget; buildConfigurationList = {ref("testconfigs")}; buildPhases = ({ref("testsources")},); buildRules = (); dependencies = ({ref("dependency")},); name = AirMarkUITests; productName = AirMarkUITests; productReference = {ref("testproduct")}; productType = "com.apple.product-type.bundle.ui-testing";')
add('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2700; BuildIndependentTargetsInParallel = YES; TargetAttributes = {{ {ref("test")} = {{ TestTargetID = {ref("app")}; }}; }}; }}; buildConfigurationList = {ref("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,ko,); mainGroup = {ref("main")}; productRefGroup = {ref("products")}; projectDirPath = ""; projectRoot = ""; packageReferences = ({ref("package")},); targets = ({ref("app")},{ref("test")},);')
project = root/'AirMark.xcodeproj'
project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+ '\n'.join(f'{key} = {{ {body} }};' for key,body in objects.items()) + f'\n}}; rootObject = {ref("project")}; }}\n')
scheme = project/'xcshareddata/xcschemes'
scheme.mkdir(parents=True, exist_ok=True)
def buildable(target,name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref(target)}" BuildableName="{name}" BlueprintName="{target == "app" and "AirMark" or "AirMarkUITests"}" ReferencedContainer="container:AirMark.xcodeproj"/>'
(scheme/'AirMark.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable('app','AirMark.app')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{buildable('test','AirMarkUITests.xctest')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable('app','AirMark.app')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable('app','AirMark.app')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(project)
