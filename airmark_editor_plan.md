# AirMark — 네이티브 macOS 마크다운 에디터 구현 계획

## Context

`/Users/baemingwan/Documents/AI/airmark` (현재 빈 디렉터리)에 새 프로젝트를 만든다. 목표는 **Swift로 만든, Mac 전용의, 아주 빠르고 가볍고 유려한 마크다운 에디터**다.

- 일체형(hybrid) 실시간 편집: 분할 미리보기 없이, 편집 중인 텍스트 자체가 스타일링·시각화된다 (Bear/Lettera 방식).
- 켜자마자 노트가 보인다: 로딩 화면·환영 창·열기 패널 없음. 마지막 문서(또는 빈 untitled 문서)가 즉시 복원된다.
- Mermaid 다이어그램과 LaTeX 수식이 별도 설정 없이 인라인으로 렌더링된다.
- 속도·UX·디자인의 기준: OpenMark, Lettera(by Bear) 수준.

사용자 결정 사항 (확인 완료):
- **문서 모델: 파일 기반** (.md 파일 직접 편집, 사이드바 없음, NSDocument)
- **최소 지원: macOS 26+** (TextKit 2 성숙 API, 최신 디자인 언어)
- **배포: 직접 배포/개인용** (샌드박스 없음, ad-hoc 또는 Developer ID 서명)

기존 프로젝트 관례(emissive, PriType-Swift)에서 가져올 것: Swift 6 strict concurrency, 앱 타깃 `MainActor` 기본 격리, Swift Testing(XCTest 금지), `AGENTS.md` + append-only `DEV_LOG.md`, 번들 ID `com.airmark.AirMark`, 로컬 SwiftPM 모듈 분리, 서드파티 의존성 최소화.

환경: macOS 27, Swift 6.4 (CommandLineTools), SDK 27.0. Xcode 27 beta는 `~/Downloads/Xcode-beta.app`에 있으나 `xcode-select`는 CLT를 가리킴.

---

## 핵심 아키텍처 결정 (요약)

| 결정 | 선택 | 이유 |
|---|---|---|
| 에디터 엔진 | **NSTextView + TextKit 2** (NSTextLayoutManager / NSTextContentStorage) | 네이티브 속도, 즉시 실행, 한글 IME·받아쓰기·맞춤법·접근성 무료. WebView 기반은 콜드 스타트·메모리·IME에서 목표 미달 |
| 스타일링 방식 | **스토리지는 순수 plain text**, `NSTextContentStorageDelegate.textContentStorage(_:textParagraphWith:)`에서 문단 단위로 속성을 얹음 | 스토리지에 속성 쓰기 없음 → 키 입력당 비용이 편집된 문단 + 상태 변화 문단에 한정. undo에 속성 노이즈 없음. 파일 저장이 그대로 plain text |
| 마크다운 파서 | **자체 증분(line-based) 스캐너** (`AirMarkCore`), 외부 파서 없음 | 하이브리드 에디터는 문법 마커의 정확한 UTF-16 범위와 "입력 중 미완성 문법"에 대한 관용이 필요. cmark류는 전체 재파싱 + 범위 매핑 비용. 범위: CommonMark 핵심 + GFM(표·체크박스·취소선) + `$…$`/`$$…$$` + ```` ```mermaid ```` |
| 블록 렌더(Mermaid/수식/이미지) | **커스텀 `NSTextLayoutFragment`** 서브클래스에서 `bottomMargin` + `renderingSurfaceBounds` 를 override 해 문단 아래 공간을 확보하고 `draw(at:in:)` 로 그림. 문서 텍스트에 가짜 문자(U+FFFC) 삽입 없음 | 스토리지 순수성 유지, 저장 파일 오염 없음, 캐럿/선택은 `textLineFragments` 기준이라 자연히 정상. (`layoutFragmentFrame` getter override 는 후속 프래그먼트를 밀지 못함 — 리뷰에서 확인) |
| LaTeX | **SwiftMath** (순수 Swift/CoreText, SPM, MIT) 를 기본 + **KaTeX(WebView) 폴백**. 렌더러는 프로토콜로 추상화 | WebView 없이 <1ms 렌더, 즉시 실행 유지. SwiftMath 는 `\,` `\;` `\middle` 등 미지원 → 실패 시 KaTeX 로 폴백, 둘 다 실패면 소스 표시 |
| Mermaid | 번들한 `mermaid.min.js`(v11 핀, MIT) 를 **문서 창 안에 숨겨 호스팅한(1×1, 스크롤뷰 뒤) 지연 생성 WKWebView** 에서 실행 → WebKit `takeSnapshot` 래스터(2x) | Mermaid는 DOM+`getBBox` 필요(JSCore 불가, 창 밖 offscreen WKWebView 는 렌더 안 됨 — 리뷰에서 확인). WebView는 첫 mermaid 블록이 나타날 때만 생성 → 콜드 스타트 영향 0 |
| 앱 셸 | **AppKit 전용 런치 경로** (`NSApplicationDelegate` + `NSDocument` + `NSWindowController`), SwiftUI는 설정 창에만 지연 사용 | 런치 시간 최소화, 문서 복원·자동저장·버전·Open Recent·iCloud Drive를 NSDocument가 무료 제공 |
| 빌드 | **순수 SwiftPM + `Scripts/bundle.sh`** 로 `.app` 조립 (PriType-Swift 패턴) | Xcode 없이 CLT만으로 빌드·테스트·실행 루프 가능. 필요 시 나중에 XcodeGen으로 `.xcodeproj` 생성 가능 |

---

## 모듈 구조

```
airmark/
├── Package.swift                 # tools 6.2, .macOS(.v26), Swift 6 language mode
├── Sources/
│   ├── AirMarkCore/              # Foundation만. 파서·라인 테이블·모델. 플랫폼 독립, 100% 테스트 대상
│   │   ├── LineTable.swift       # UTF-16 오프셋 기반 라인 인덱스, 증분 갱신
│   │   ├── BlockScanner.swift    # 라인별 블록 분류 + 캐리 상태(펜스/수식블록/front matter), 고정점 재스캔
│   │   ├── InlineScanner.swift   # 문단 내 스팬(강조/코드/링크/이미지/취소선/인라인수식), 마커 범위 분리
│   │   ├── MarkdownModel.swift   # 편집 델타 → 재스캔 → 변경된 라인 집합 반환
│   │   └── Types.swift           # LineKind, InlineSpan, FenceKind(.code(lang) / .mermaid / .math)
│   ├── AirMarkEditor/            # AppKit. NSTextView/TextKit 2 계층
│   │   ├── MarkdownTextView.swift        # NSTextView 서브클래스, TK2 설정, 키 동작
│   │   ├── EditorController.swift        # 스토리지 델타 ↔ MarkdownModel ↔ 레이아웃 무효화
│   │   ├── ParagraphStyler.swift         # LineInfo+InlineSpan → 속성 (기존 속성 위에 레이어)
│   │   ├── Theme.swift                   # 폰트(SF Pro 광학 사이즈, SF Mono), 색, 간격, 라이트/다크
│   │   ├── RenderedBlockLayoutFragment.swift  # 블록 렌더 결과를 문단 아래 그리는 커스텀 프래그먼트
│   │   └── SmartTyping.swift             # 리스트 계속, 탭 들여쓰기, 자동 짝, 체크박스 토글
│   ├── AirMarkRender/            # 렌더러. 모두 캐시(콘텐츠 해시 LRU) + 비동기, 출력은 디코드된 CGImage
│   │   ├── BlockRenderer.swift   # 프로토콜: render(source, theme, scale) async -> CGImage? / 에러
│   │   ├── MathRenderer.swift    # SwiftMath (actor 로 직렬화, @preconcurrency import) → 실패 시 KaTeXRenderer
│   │   ├── KaTeXRenderer.swift   # 번들 katex.min.js, WebHost 공유 (Phase 2 후반)
│   │   ├── MermaidRenderer.swift # WebHost 위에서 mermaid.render → takeSnapshot 래스터, 테마, 에러
│   │   ├── WebHost.swift         # 지연 생성 WKWebView 1개(창 내 hidden 호스팅). 네트워크 전면 차단, 요청 직렬 큐
│   │   ├── ImageLoader.swift     # 문서 상대경로(기본) + 원격 URL(기본 off, 옵션), 컬럼 폭 다운스케일
│   │   └── RenderCache.swift
│   └── AirMark/                  # 앱 (실행 파일)
│       ├── main.swift / AppDelegate.swift
│       ├── MarkdownDocument.swift        # NSDocument: UTF-8 읽기/쓰기, autosavesInPlace
│       ├── EditorWindowController.swift  # 풀사이즈 콘텐츠, 투명 타이틀바, 중앙 컬럼
│       ├── MainMenu.swift                # 코드로 구성한 메뉴 (xib 없음)
│       └── Settings/ (SwiftUI, 지연 로드)
├── Resources/                    # Info.plist, AirMark.entitlements(없거나 최소), AppIcon.icns, mermaid.min.js
├── Tests/AirMarkCoreTests/       # Swift Testing: 스캐너 정합성, 증분 재스캔 == 전체 스캔, 성능
├── Tests/AirMarkEditorTests/     # 스타일링 결과(범위→속성) 검증
├── Scripts/                      # bundle.sh, run.sh, bench_launch.sh, make_icon.sh
├── AGENTS.md (+ CLAUDE.md → symlink), DEV_LOG.md, README.md, .gitignore
```

모듈 의존 방향(컴파일러로 강제): `AirMark → AirMarkEditor → {AirMarkCore, AirMarkRender}`, `AirMarkRender → AirMarkCore`. `AirMarkCore`는 AppKit을 import하지 않는다.

---

## 세부 설계

### 1. 파서 (`AirMarkCore`)
- **LineTable**: 각 라인의 UTF-16 범위. 편집 `(range, delta)` 를 받아 영향 라인만 재계산. **문단 구분자 집합은 TextKit 과 동일** (`\n`, `\r`, `\r\n`, U+2028, U+2029) — 그렇지 않으면 라인↔`NSTextParagraph` 가 어긋나 델리게이트 범위가 틀어진다. 로드 시 LF 로 정규화(원본 줄바꿈 종류는 문서에 기억해 저장 시 복원).
- **BlockScanner**: 라인 하나를 `(이전 라인의 carry state) → (LineKind, new carry state)` 로 분류. carry state = `.none | .inFence(kind, indent) | .inMathBlock | .inFrontMatter`. **재스캔 시작점은 편집된 첫 라인의 직전 라인(또는 컨테이너 시작)** — setext `===`/`---`, 표 header+delimiter 처럼 라인 N 의 편집이 N-1 의 kind 를 바꾸는 2-라인 lookahead 때문. 어떤 라인의 (kind, state)가 이전 결과와 같아지는 지점에서 멈춤(고정점). 펜스를 여는 한 글자 입력이 문서 끝까지 상태를 바꾸는 경우도 정확히 처리.
- 명시적 규칙: `---` 의 4중 의미(hr / setext / front matter(문서 첫 줄만) / 표 delimiter) 우선순위 고정; 리스트 내용 컬럼 = 마커 폭 + 1~4칸, 그 안의 펜스 indent 허용; lazy continuation 은 단순 규칙(빈 줄 전까지 문단 계속)만; 들여쓰기 코드블록은 **비활성**(중첩 리스트와 충돌); 한 라인이 10k UTF-16 초과면 인라인 스캔 생략.
- **v1 컷**: 링크 참조 정의(`[id]: url`)는 라인 kind 로만 분류(문서 전역 해석 없음), `[t][id]` 는 해석 없이 링크 스타일. 인라인 HTML 은 패스스루.
- LineKind: `paragraph, heading(level, atx), setextUnderline, blank, hr, quote(depth, inner), listItem(marker, ordered, indent, task: nil|checked|unchecked, inner), fenceOpen(kind, lang), fenceBody(kind), fenceClose(kind), table(header|delimiter|row), frontMatter, htmlBlock(패스스루)`.
- **InlineScanner**: 문단 텍스트(quote/list 접두 제거 후 inner 범위)에서 delimiter-stack 기반으로 `**strong**`, `*em*`, `` `code` ``, `~~strike~~`, `[text](url)`, `![alt](src)`, `<autolink>`, `$inline$` 스팬을 찾고, 각 스팬을 `markerRanges` + `contentRange` 로 분리. 미완성 문법(닫히지 않은 `**`)은 plain 처리. flanking 규칙은 CJK 에 관대하게(스펙의 punctuation/whitespace 규칙을 한글에 강요하지 않음). `$` 는 Pandoc 규칙(여는 `$` 뒤 공백 금지, 닫는 `$` 앞 공백 금지·뒤에 숫자 금지)으로 가격 표기 오탐 방지. 결과는 라인별 캐시, 라인 변경 시 무효화.
- 테스트: (a) 문법별 골든 케이스, (b) **무작위 편집 fuzz — 증분 재스캔 결과 == 전체 재스캔 결과**, (c) 1MB 문서 전체 스캔 < 20ms, 단일 라인 편집 재스캔 < 0.2ms, (d) **테스트 전용 의존성으로 `swift-markdown` 을 블록 분류 오라클** 로 사용(앱 타깃엔 링크 안 됨) — 우리 스캐너의 라인 kind 와 cmark 블록 경계가 어긋나는 케이스를 싸게 발견, (e) CRLF/U+2028 문서의 라인↔문단 동기화.

### 2. 에디터 (`AirMarkEditor`)
- `MarkdownTextView`: `isRichText = false`(typingAttributes 가 스토리지로 새지 않게 하는 핵심), 스마트 따옴표/대시/자동 치환 off, 폰트 패널 off, `allowsUndo`, TK2 강제 확인(설정 후 `textLayoutManager != nil` assert, `NSTextView.willSwitchToNSLayoutManagerNotification` 관찰해 TK1 폴백을 즉시 로그). **`layoutManager` 접근 금지, 편집 뷰로 인쇄 금지** (둘 다 TK1 폴백 트리거 — AGENTS.md 규칙으로 명문화). 컬럼 최대 폭 680pt, 창 리사이즈 시 `textContainerInset`으로 중앙 정렬. 맞춤법 검사는 코드/URL/수식 범위 제외(`textView(_:willCheckTextIn:options:types:)`).
- `EditorController`: `NSTextStorageDelegate.textStorage(_:didProcessEditing:range:changeInLength:)` → `MarkdownModel.apply(edit)` → 변경 라인 집합. 편집 범위 안의 문단은 TextKit 이 알아서 요소를 재생성한다. **편집 범위 밖에서 상태가 바뀐 문단(예: 펜스 열림으로 이후 라인들)은 `NSTextContentStorage` 가 `NSTextParagraph` 를 캐시하고 있어 `invalidateLayout(for:)` 만으로는 델리게이트가 재호출되지 않는다** → 해당 범위에 `textStorage.edited([.editedAttributes], range:changeInLength: 0)` 을 `performEditingTransaction` 안에서 호출해 요소 재생성을 강제. 이는 `didProcessEditing` 콜백 안에서 재진입하면 안 되므로 **다음 runloop 턴으로 미룬다**. **IME 조합 중(`hasMarkedText()`)에는 재스캔을 미루고 커밋 시 처리** (한글 입력 필수 고려).
- `textContentStorage(_:textParagraphWith:)` 구현: 반환 문단은 **문자 수·범위를 반드시 보존**(display 속성만 추가). 원본 문단의 속성(마크드 텍스트 밑줄 등)을 **덮어쓰지 않고 위에 `addAttributes`**. 레이아웃에 영향을 주는 속성(폰트·크기·문단 스타일)만 여기서, 색·밑줄 같은 렌더 전용 속성은 `NSTextLayoutManager.setRenderingAttributes(_:for:)` 로 분리해 색 변경(테마 전환, 캐럿 문단 강조)은 요소 재생성 없이 처리. 스타일: 헤딩 크기/굵기, 마커(`#`, `**`, `` ` ``)는 옅은 색으로 항상 표시(레이아웃 안정), 코드는 SF Mono + 배경, 인용은 좌측 들여쓰기 + 세로 바, 리스트는 hanging indent(`NSTextList` 는 사용하지 않음 — 델리게이트 경로와 충돌 보고 있음, 문단 indent 로 직접 구현), 표는 컬럼 폭을 계산한 탭 스톱(한글은 SF Mono 에서도 2폭이라 파이프 정렬이 안 맞음), 링크는 색상 + 밑줄 없음 + **⌘클릭만 열기**(`clickedOnLink` 제어), 체크박스는 `[ ]`/`[x]`를 SF Symbol 대체(클릭 토글).
- **커서 위치 기반 마커 노출(conceal)** 은 Phase 3. v1은 Bear식 "항상 보이는 옅은 마커".
- `RenderedBlockLayoutFragment`: `NSTextLayoutManagerDelegate.textLayoutManager(_:textLayoutFragmentFor:in:)` 에서 (a) mermaid/수식 펜스의 닫는 라인 (b) `![]()` 단독 문단 (c) 표 문단(선택) 에 대해 반환. **`bottomMargin`(= 이미지 높이 + 여백) 과 `renderingSurfaceBounds` 를 override** 해 공간을 확보하고 `draw(at:in:)` 에서 텍스트 라인 뒤에 캐시된 `CGImage` 를 그림(`NSImage` 직접 드로잉 금지 — 스크롤 120Hz). `textLineFragments` 는 절대 override 하지 않음(렌더·선택 파괴). 대안 경로: macOS 26 의 `NSTextViewportLayoutControllerDelegate.textViewportLayoutController(_:configureRenderingSurfaceFor:)` + `NSTextViewportRenderingSurface` 로 CALayer 를 호스팅. 렌더 결과가 아직 없으면 placeholder 높이(직전 결과 캐시 or 최소 높이) → 완료 시 해당 요소만 무효화. 렌더 오류는 소스 아래 한 줄 에러 텍스트. 이미지 영역 클릭은 인접 라인으로 hit-test 되는 것을 허용.
- `SmartTyping`: Enter → 리스트/인용/체크박스 계속(빈 항목에서 Enter는 해제), Tab/⇧Tab → 리스트 들여쓰기, ⌘B/⌘I/⌘K/⌘E(code) 선택 감싸기, `(`/`[`/`` ` `` 자동 짝(선택 텍스트 감싸기), ⌘⏎ 체크박스 토글, ⌘1~6 헤딩. 붙여넣기: URL 을 선택 위에 붙이면 `[선택](url)`, 클립보드 이미지/드롭 파일은 문서 옆 `assets/` 에 저장 후 `![]()` 삽입. 모두 undo 가능(`shouldChangeText` 경유).

### 3. 렌더러 (`AirMarkRender`)
- `BlockRenderer` 프로토콜: `render(source, theme, scale) async throws -> CGImage`. 모든 렌더러가 구현, `RenderCache` 키 = hash(source, theme, scale).
- `MathRenderer`: SwiftMath `MTMathImage(latex:fontSize:textColor:labelMode:).asImage()` 로 디스플레이 수식(`$$…$$` / ```` ```math ````)을 폰트 크기·색(라이트/다크) 맞춰 렌더. **SwiftMath 는 Swift 5 모드·전역 mutable 싱글턴(`MTFontManager`)이라 반드시 단일 actor 로 직렬화하고 `@preconcurrency import`** — 백그라운드 병렬 호출은 데이터 레이스. 렌더 실패(미지원 명령 `\,` `\;` `\middle` 등) 시 `KaTeXRenderer` 로 폴백, 그것도 실패면 소스 표시 + 에러.
- `WebHost`: 첫 요청 시 `WKWebView` 1개 생성해 **문서 창 `contentView` 에 스크롤뷰 뒤 1×1 로 붙임**(창 밖 offscreen 은 WebKit 이 렌더링을 돌리지 않아 `getBBox` 가 0 → mermaid 레이아웃 붕괴). HTML 컨테이너는 `display:none`/`visibility` 대신 `position:absolute; left:-9999px`. `loadHTMLString(baseURL: nil)` 또는 리소스 디렉터리 한정 `loadFileURL`, `WKContentRuleList` 로 네트워크 전면 차단, 요청 직렬 큐, `document.fonts.ready` 후 렌더.
- `MermaidRenderer`: 번들 `mermaid.min.js`(**v11.x 핀**, UMD, MIT LICENSE 동봉), `mermaid.initialize({ startOnLoad:false, securityLevel:'strict', theme })`. `mermaid.render(id, src)` 후 컨테이너를 `<svg>` 크기로 리사이즈 → **`takeSnapshot(WKSnapshotConfiguration)` 래스터(2x) 가 기본 경로**. `NSImage(data:)` SVG 경로는 CoreSVG 가 mermaid 의 class-selector CSS 를 부분 해석해 색/스트로크가 깨질 가능성이 커 옵션으로만. 외형(라이트/다크) 바뀌면 캐시 키에 테마 포함해 재렌더. v10+ 의 dynamic import 로 지연 로드되는 다이어그램 타입(zenuml 등)이 오프라인 번들에서 동작하는지 스파이크에서 확인.
- `ImageLoader`: 문서 URL 기준 상대 경로(기본). 원격 URL 은 **기본 off**(추적 픽셀/프라이버시), 설정으로 켜면 `URLSession` + 디스크 캐시. 컬럼 폭에 맞춰 다운샘플(`CGImageSource` thumbnail).
- 비용 인지: 첫 WebView 생성은 WebContent/Networking 프로세스 spawn(~100–300ms, 합산 +50–80MB). 그래서 지연 생성이고, 메모리 예산도 "mermaid 사용 시" 로 분리.

### 4. 앱 (`AirMark`)
- 런치: `main.swift` → `NSApplication` → `AppDelegate`. 상태 복원 켬(`applicationSupportsSecureRestorableState` = true, 마지막 창·문서 자동 복원). **상태 복원 ≠ 마지막 문서 복원**: 창을 닫고 종료했으면 복원 대상이 없으므로, 복원된 창이 0개면 `NSDocumentController.recentDocumentURLs.first` 를 열고, 그것도 없으면 untitled 문서를 연다. SwiftUI/WebKit/SwiftMath 는 런치 경로에서 **인스턴스 생성을 지연**(정적 링크된 프레임워크는 dyld 가 어차피 로드하므로 링크 자체를 피하는 게 아님 — shared cache 라 수~십 ms, 실측으로 허용 여부 판단).
- `MarkdownDocument: NSDocument`: UTF-8 read(실패 시 `NSString.stringEncoding(for:)` 로 추정, BOM 처리) / UTF-8 write, 줄바꿈 종류(LF/CRLF)와 후행 개행 여부를 기억해 저장 시 보존. `autosavesInPlace = true`, `canAsynchronouslyWrite = true`. 외부 변경 감지(`presentedItemDidChange`) 시 미저장 편집이 없으면 조용히 리로드(선택·스크롤 보존), 있으면 충돌 안내. `NSDocumentClass` 는 모듈 한정 이름 `AirMark.MarkdownDocument`. 문서 타입 `net.daringfireball.markdown`(`UTImportedTypeDeclarations` 로 선언), `public.plain-text` (md, markdown, txt). 대용량 가드: 파일이 N MB(초기값 4MB) 초과면 스타일링·블록 렌더 off 로 열기.
- 창: `.fullSizeContentView`, 투명 타이틀바(파일명은 표시), 툴바 없음, 하단에 조용한 단어 수(옵션). 라이트/다크 자동, 시스템 강조색 사용. 확대/축소(⌘+/−)는 테마 base size 변경.
- 메뉴: File(New/Open/Open Recent/Save/Revert To ▸ Browse All Versions/Export…), Edit(표준 + Find·Replace ⌘F/⌥⌘F: `NSTextFinder` 사용 — 델리게이트 스타일링과 공존 여부 스파이크 A 에서 확인), Format(헤딩/강조/리스트/체크박스), View(폭·타이프라이터·포커스 모드·확대/축소), Window, Help.
- 설정(SwiftUI, 지연): 폰트 크기, 컬럼 폭, 줄 간격, 마커 표시 방식.

### 5. 성능 예산 (측정 가능, `Scripts/bench_launch.sh` + signposts)
| 항목 | 목표 |
|---|---|
| 콜드 런치 → 마지막 문서(기준 50KB)가 그려진 첫 프레임 | < 150 ms (Apple Silicon) |
| 100KB 문서 키 입력 → 재스캔+무효화 완료 | < 2 ms (렌더 제외) |
| 100KB 문서 키 입력 → 다음 프레임 표시 (TK2 재레이아웃 포함, 사용자 체감) | < 8 ms (120Hz 한 프레임) |
| 1MB 문서 열기 → 첫 화면 | < 300 ms (TK2 뷰포트 지연 레이아웃) |
| 유휴 메모리 (WebView 미생성) | < 40 MB |
| 유휴 메모리 (mermaid 사용 후, WebContent 프로세스 합산) | < 120 MB |
| 스크롤 | 120Hz 유지, 뷰포트 밖 레이아웃 없음, 프래그먼트 draw 에서 `CGImage` 만 |
| 앱 크기 | < 15 MB (mermaid.min.js ~2.5MB, katex ~1MB 포함) |

측정: `AIRMARK_BENCH=1` 이면 프로세스 시작(`kinfo_proc` start time) → 첫 `NSWindow.didBecomeKey` 후 다음 프레임까지 경과를 stderr에 출력. pre-main 분리는 `DEVELOPER_DIR=~/Downloads/Xcode-beta.app/Contents/Developer xctrace record --template 'App Launch'`. `os_signpost` 구간: `rescan`, `invalidate`, `paragraphStyle`, `mermaid.render`, `math.render`.

---

## 단계별 실행 계획

### Phase 0 — 스캐폴드 + 리스크 스파이크 (선행, 각 스파이크는 타임박스)
1. `Package.swift`, 모듈 뼈대, `Scripts/bundle.sh`(swift build → `.app` 조립 → `Bundle.module` 리소스 번들 위치 확인 → ad-hoc codesign), `Scripts/run.sh`, `.gitignore`, `AGENTS.md`(+`CLAUDE.md` symlink), `DEV_LOG.md`, `git init`.
2. **스파이크 A (TK2 문단 델리게이트)**: plain 스토리지 + `textParagraphWith` 로 헤딩/강조 스타일 → 타이핑, 한글 조합(마크드 텍스트), undo 검증. **핵심 검증**: 펜스를 열어 이후 문단 상태가 바뀔 때 편집 범위 밖 문단이 `edited(.editedAttributes)`(콜백 밖, 다음 runloop) 로 재생성되는지; `setRenderingAttributes` 로 색만 바꿀 때 요소 재생성이 없는지; CRLF/U+2028 문서에서 라인↔문단 동기화; `NSTextFinder`·맞춤법 밑줄이 델리게이트 스타일링과 공존하는지; TK1 폴백 알림이 한 번도 안 뜨는지. 실패 시 폴백: `NSTextStorage` 서브클래스 `processEditing` 에서 속성 적용(검증된 전통 방식).
3. **스파이크 B (커스텀 레이아웃 프래그먼트)**: 두 갈래 — (1) `bottomMargin` + `renderingSurfaceBounds` override + `draw` 로 이미지, (2) macOS 26 `configureRenderingSurfaceFor` 렌더링 서피스에 CALayer 호스팅. 캐럿/선택/스크롤/`usageBoundsForTextContainer` 가 깨지지 않는지, 편집 직후 프래그먼트 높이 오차(알려진 TK2 버그)가 재현되는지 확인.
4. **스파이크 C (Mermaid 호스팅)**: 문서 창 `contentView` 에 스크롤뷰 뒤 1×1 로 붙인 WKWebView 에서 `mermaid.render` → `takeSnapshot` 2x 품질/지연 측정. 네트워크 차단 룰 적용 상태에서 flowchart/sequence/class/gantt/mindmap 이 오프라인 번들로 동작하는지. `NSImage(data:)` SVG 경로는 참고 비교만.
5. **스파이크 D (SwiftMath)**: Swift 6 언어 모드 앱에서 `@preconcurrency import` 로 빌드, actor 직렬화, `MTMathImage.asImage()` 출력, 다크모드 색, 대표 수식 코퍼스(분수/합/행렬/`aligned`/`cases`/`\text`) 커버리지 표. KaTeX 폴백은 같은 WebHost 에서 snapshot 으로 확인.
6. 각 스파이크 결과를 `DEV_LOG.md` 에 기록하고 설계 확정.

### Phase 1 — 사용 가능한 에디터 (MVP)
- `AirMarkCore` 파서 전체 + 테스트(골든 + fuzz + 성능).
- `MarkdownTextView`/`EditorController`/`ParagraphStyler`/`Theme`: 헤딩·강조·코드(인라인/펜스)·인용·리스트·체크박스·링크·표(mono)·hr·front matter 스타일링.
- `NSDocument` 앱 셸, 복원(+ 최근 문서 폴백), 자동저장, 인코딩/줄바꿈 보존, 외부 변경 리로드, 메뉴, 찾기/바꾸기(⌘F), 확대/축소.
- `SmartTyping` 최소 집합: Enter 리스트/체크박스 계속, Tab 들여쓰기, ⌘B/⌘I/⌘K (하루 사용 기준에 필요).
- 즉시 실행 측정 스크립트 + 첫 예산 측정치 기록.
- **완료 기준**: 실제 노트 파일로 하루 사용 가능. 런치/타이핑 예산 충족.

### Phase 2 — 블록 시각화
- `RenderedBlockLayoutFragment` + `AirMarkRender` 통합: ```` ```mermaid ````, `$$…$$`·```` ```math ````, `![]()` 이미지(로컬).
- 비동기 렌더 → 요소 단위 무효화, 캐시, 라이트/다크 재렌더, 에러 표시.
- 후반: `KaTeXRenderer` 폴백 연결, 원격 이미지 옵션.
- **완료 기준**: 설정 없이 세 종류 블록이 타이핑 중 실시간 갱신(디바운스 150ms), 스크롤 성능 유지, mermaid 사용 시 메모리 예산 이내.

### Phase 3 — 편집 경험·디자인 폴리시
- `SmartTyping` 전체(붙여넣기/드롭 동작 포함), 체크박스 클릭 토글, 링크 ⌘클릭 열기.
- **conceal 모드**(옵션): 캐럿이 없는 문단의 문법 마커 숨김. Apple DTS 권장 경로(hidden range + 커스텀 프래그먼트가 건너뛰어 그리기)는 `textLineFragments` 커스텀이 필요해 실질적으로 막혀 있음 → 속성 트릭: 마커 글자에 극소 폰트 + `.foregroundColor: .clear` + 음수 `.kern` 으로 폭을 0 근처로; 캐럿 진입 시 문단 재스타일(레이아웃 소폭 이동은 Typora/Obsidian 과 동일하게 허용). 인라인 `$…$` 는 **마지막 마커 글자에 양수 `.kern` = 렌더 이미지 폭** 을 주어 레이아웃 공간을 확보하고 프래그먼트 `draw` 에서 그 자리에 이미지를 그림(캐럿/선택 rect 가 자연히 맞음; 높이는 줄 높이에 맞춰 스케일). 스파이크로 선택 하이라이트 sliver, 줄 높이 변화, VoiceOver 를 확인.
- 타이프라이터/포커스 모드, 폭·크기 설정, 단어 수, 문서 내 아웃라인 이동(⌘⇧O 팝오버).
- 디자인: 광학 사이즈, 문단 간격, 리스트 hanging indent 정렬, 다크모드 대비, 선택 색, 캐럿 애니메이션 없음(즉답성).

### Phase 4 — 하드닝·부가 기능
- 성능 회귀 테스트(1MB 문서 fuzz 타이핑), 메모리 프로파일, 접근성(VoiceOver 헤딩 읽기), ko/en 로컬라이즈.
- Export: HTML(수식·mermaid는 렌더 이미지 임베드)/PDF — **편집 뷰의 인쇄 경로는 사용 금지**(TK1 폴백 트리거). 별도 offscreen `NSTextLayoutManager` 를 같은 델리게이트로 구성해 페이지 단위로 직접 드로잉.
- 앱 아이콘(`iconutil`), Developer ID 서명·notarize 스크립트(PriType 스크립트 참고).

### v1 비목표 (명시적으로 안 함)
동기화/태그/라이브러리, 분할 미리보기, 플러그인, WYSIWYG 툴바, 협업, 인라인 HTML 렌더링, Windows/iOS.

---

## 주요 리스크와 대응
| 리스크 | 대응 |
|---|---|
| TK2 문단 델리게이트: 편집 범위 밖 문단 재생성 누락, 마크드 텍스트/undo/`NSTextFinder` 충돌, Apple 내부에서도 덜 검증된 경로 | 스파이크 A로 조기 검증(`edited(.editedAttributes)` 지연 호출 포함), 폴백 경로(`NSTextStorage` 서브클래스) 확보 |
| 커스텀 프래그먼트: `bottomMargin` 확장 시 캐럿/선택/`usageBounds` 이상, 편집 직후 높이 오차 버그 | 스파이크 B 두 갈래(`bottomMargin` vs macOS 26 렌더링 서피스); 둘 다 안 되면 문단 아래 별도 오버레이 `NSView`(프래그먼트 frame 좌표) |
| WKWebView 호스팅: 창 내 hidden 뷰가 특정 상황(창 minimize, 다른 Space)에서 렌더 정지 | 렌더 요청에 타임아웃 + 재시도, 창이 visible 해질 때 큐 재개 |
| WebKit 프로세스 비용(런치·메모리) | 첫 mermaid 블록까지 생성 안 함, 문서에 mermaid 가 없어지면 idle 후 해제(옵션) |
| SwiftMath: 커버리지 부족, 전역 싱글턴, 단일 메인테이너 | actor 직렬화, 프로토콜 추상화, KaTeX 폴백, 실패 시 소스 표시 |
| 커스텀 파서 엣지케이스(2-라인 lookahead, `---` 다의성, 리스트 indent) | 재스캔 시작점 N-1, 골든 + fuzz(증분==전체) + swift-markdown 오라클 테스트, 스코프를 명시된 문법 집합으로 제한 |
| SwiftPM `.app` 조립의 `Bundle.module` 경로, `NSDocumentClass` 모듈명, 재서명 시 TCC 초기화 | PriType `build_debug.sh` 패턴(리소스 번들을 `Contents/Resources` 로 복사) 참고, Phase 0 에서 검증 |
| 문단 구분자 불일치(CRLF, U+2028) 로 스타일 범위 오프셋 | 로드 시 LF 정규화 + LineTable 구분자 집합을 TextKit 과 동일하게 + 테스트 |

---

## 검증 방법
- `swift test` (CLT만으로): 파서 골든/fuzz/성능, 스타일러 범위→속성 테스트.
- `Scripts/run.sh` 로 앱 실행 후 수동 시나리오: 새 문서 타이핑(한글 조합 포함), 펜스 열고 닫기(이후 문단 스타일이 즉시 바뀌는지), mermaid/수식/이미지 블록 입력, 다크모드 전환, 창 닫고 종료 후 재실행 시 문서 즉시 복원, CRLF 파일 열고 저장 후 diff 없음, 1MB 샘플 문서 스크롤, 콘솔에 TK1 폴백 로그 0건.
- 리뷰 반영 이력: 이 계획은 별도 서브에이전트의 비판적 검토(TextKit 2 프래그먼트 확장 방식, offscreen WKWebView, 델리게이트 무효화, 스캐너 lookahead, SwiftMath 동시성, v1 누락 항목)를 반영해 수정됨. 검토 근거 링크는 `DEV_LOG.md` 첫 항목에 옮겨 적는다.
- `Scripts/bench_launch.sh` 10회 평균 런치 시간이 예산 이내인지 확인, 결과를 `DEV_LOG.md`에 기록.
- Instruments(Xcode beta 필요 시 `DEVELOPER_DIR` 지정)로 타이핑 중 메인 스레드 히치 확인.
