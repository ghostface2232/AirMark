# AirMark 코드 검토와 최적화 — 2026-09-16

## 범위와 판단 기준

기준 커밋은 `f9ec70f`이며 시작 시 작업 트리는 깨끗했다. 최근 10개 커밋, PLAN.md, 코어·편집기·렌더러·문서·앱 진입점, 기존 테스트와 측정 스크립트를 검토했다. 번들된 KaTeX/Mermaid 전체 코드나 upstream swift-markdown 내부에 대한 보안 감사는 수행하지 않았다.

기준은 원문 바이트 보존, 명시적인 결과 적용 조건, 유한한 자원 사용, 실제 사용 경로의 측정, 재현 가능한 검증이다. 특정 개발자의 이름이나 코드 규모를 품질 보증으로 삼지 않는다.

`47463a7`의 화면 밖 무효화 지연과 스타일 인덱스는 타당하다. `581bfa2`의 종료 시 동기 복구 저장은 main actor 대기 문제를 해결하지만 비동기 저장과의 순서 보장이 빠져 있었다. `f9ec70f`의 접근성 검사는 개별 설명을 확인하므로 캐시를 공유하는 두 이미지의 설명 혼동을 잡지 못했다.

## 실행한 절차

1. 변경 전 Swift 테스트 35개와 Release 파서 벤치마크를 실행했다.
2. 외부 파일 복원, Save As 후 재저장, 이미지 설명 재사용, IME 속성에 대한 회귀 검사를 추가했다. 변경 전 실제 실패를 확인했다.
3. 긴 한 줄에 대해 위치 조회와 파싱을 따로 측정했다. 실패 원인과 성능 병목을 분리했다.
4. 문서 저장 정책, 복구 기록 순서, 표시 결과 유효성, 위치 변환만 수정했다. 문법 엔진·TextKit 2 구조·원문 저장 방식은 유지했다.
5. UTF-8의 모든 바이트 열을 독립적인 디코딩 결과와 비교하고, 400회 무작위 편집 후에도 검증했다. Release 전체 Swift 테스트 43개가 통과했다. 입력기 표시와 클릭 경쟁을 수정한 뒤 최종 전체 UI 테스트 5개도 단일 실행에서 모두 통과했다(`/tmp/airmark-review-complete-20260916.xcresult`). 동일 벤치마크로 성능도 확인했다.

## 수정한 문제

| 중요도 | 재현 또는 코드 근거 | 수정과 검증 |
|---|---|---|
| P1 | 파일 A를 읽고 B로 저장한 뒤 외부에서 A로 복원하면 `ownContents`가 자기 저장으로 오인했다. | 현재 저장 바이트만 비교한다. 비동기 읽기 도중 저장 기준이나 파일 경로가 바뀌면 관측을 버린다. 외부 복원·연속 저장 회귀 검사 통과. 과거 전체 파일을 최대 16개 보관하던 배열도 제거. |
| P1 | 외부 충돌 후 Save As는 성공하지만 `externalConflict`가 남아 다음 저장이 실패했다. | 성공한 Save As 후 충돌 해제. 원래 충돌 파일 보존과 새 파일의 두 번째 저장까지 검사. 실패한 저장은 기준 바이트와 dirty 상태를 유지한다. |
| P1 | 종료 시 static writer가 actor의 revision 검사를 우회했다. 이전 비동기 쓰기가 최신 종료 기록을 덮을 수 있었다. | 같은 RecoveryStore의 동기·비동기 쓰기를 하나의 잠금과 순서 검사로 직렬화. revision 우선, 같은 revision은 기록 날짜로 판별. 더 오래된 내용과 선택 기록의 사후 적용 거부 검사. |
| P1 | marked text의 문자는 보존하지만 글꼴·문단 속성은 계속 바꿨다. | 조합 중인 문단은 원래 attributed substring을 반환한다. marked 범위의 문자뿐 아니라 속성까지 원본과 비교. 커밋 후 한글 굵게 표시·caret 검사 유지. |
| P2 | 참조 이미지의 정의만 바꾸면 이미지 범위는 같아 이전 픽셀이 남았다. | 새 parse 적용 시 요소의 범위·종류·콘텐츠·설명이 모두 같은 경우만 artifact를 보존. 존재하는 이미지에서 없는 참조 대상으로 변경하는 통합 검사 추가. |
| P2 | 같은 이미지와 환경을 공유하는 두 요소가 첫 번째 alt 설명을 공유했다. | 픽셀 캐시는 공유하고 접근성 설명은 요청 요소에서 결합. 설명 차이와 CGImage 동일성을 동시에 검사. |
| P2 | Save To로 복사본을 내보내면 원본 파일의 저장 기준까지 바뀌었다. | 복사본 내보내기는 원본 기준을 갱신하지 않는다. 원본·복사본 바이트와 후속 일반 저장 검사. |
| P2 | 측정 스크립트가 테스트 실패를 무시하고 첫 실행을 근거 없이 cold라고 표시했다. 백분위 계산도 nearest-rank와 달랐다. | 실패 로그를 출력하고 비정상 종료, OS 캐시 상태 미통제 표시, `ceil(p*n)` 사용. 스크립트 문법 검사. 이번에는 전체 launch/memory 스크립트를 다시 실행하지 않았다. |
| P2 | 영문 UI 입력 테스트가 활성 한글 입력기에 의존했다. | 실제로 `Save`가 `ㄴㅁㅍㄷ`로 입력되는 실패 확인. 입력 테스트가 공개 TIS API로 선택 가능한 ASCII 입력 소스를 선택하고 teardown에서 기존 입력기를 복원한다. 반복 저장은 키보드만 사용해 입력기 표시와 클릭의 경쟁을 피한다. 실제 한글 IME 사용자 검증을 대체하지 않는다. |

## 성능 변경과 실측

기존 `SourceIndex.offset`은 AST 위치마다 줄 전체를 String과 UTF-8 배열로 만들고, 해당 접두사를 다시 디코딩했다. 한 줄의 길이와 노드 수가 함께 커질 때 이 작업이 제곱에 비례해 증가했다.

현재는 원문 UTF-16 배열을 공유하고, 약 64 코드 단위마다 scalar 경계의 UTF-8/UTF-16 대응점을 기록한다. 각 조회는 이진 탐색 후 최대 65 UTF-16 단위만 읽는다. surrogate pair 내부와 UTF-8 멀티바이트 내부 위치는 거부한다. Markdown의 CR/LF/CRLF 경계와 U+2028/U+2029의 차이를 유지한다. 파서에서도 원문이 필요하지 않은 AST 노드의 substring 생성을 제거했다.

환경: Mac17,3, 24 GiB, arm64, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4, Release. OS 캐시는 통제하지 않았다. 원시 수치는 `Validation/2026-09-16-review/`에 있다.

| 입력 / 측정 | 변경 전 p50 | 변경 후 p50 | 반복 수 |
|---|---:|---:|---:|
| 일반 99,912 bytes 파싱 | 40.219 ms | 33.648 ms | 20 |
| 일반 999,948 bytes 파싱 | 400.562 ms | 342.762 ms | 10 |
| 일반 9,999,894 bytes 파싱 | 4,106.253 ms | 3,534.830 ms | 3 |
| 한 줄 15,000 bytes 파싱 | 130.182 ms | 6.749 ms | 5 |
| 한 줄 60,000 bytes 파싱 | 2,039.388 ms | 15.660 ms | 5 |
| 한 줄 240,000 bytes 파싱 | 32,533.939 ms | 62.585 ms | 5 |
| 같은 240KB 줄의 16,000개 위치 조회 | 5,397.623 ms | 1.657 ms | 5 |

일반 문서 파싱은 약 14–16% 단축됐다. 긴 줄 결과는 특정 병목의 제거를 보여주며 모든 문서가 520배 빨라진다는 뜻이 아니다. 초기 위치 인덱스 구성에는 메모리·시간 비용이 추가된다. 1MB 인덱스 생성 p50은 4.058 → 4.475ms였으며, 위 파싱 수치는 그 비용을 포함한다. `SourceIndex.apply`는 줄의 suffix를 갱신하지만 대응점 인덱스는 다시 구성한다. 현재 편집기의 입력 경로는 이 API를 호출하지 않는다.

재현 명령:

```sh
swift test --disable-sandbox
swift test -c release --disable-sandbox
swift run -c release --disable-sandbox AirMarkBench
swift run -c release --disable-sandbox AirMarkBench --long-lines
swift test -c release --disable-sandbox --filter ScaleTests
AIRMARK_TEST_RESULTS=/tmp/airmark-review.xcresult bash Scripts/test-ui.sh -configuration Release
```

입력 지연은 별도 결과다. 최종 독립 Release ScaleTests의 편집기 단독 p50/p95/max는 **3.69/9.05/10.26ms**였다. NSDocument 콜백을 포함한 앞·중간·뒤 입력 p95는 각각 **3.93/3.78/3.51ms**였다. 두 테스트는 창·viewport·렌더 상태가 달라 서로 비교해 문서 콜백이 더 빠르다고 해석하면 안 된다. 편집기 단독 p95는 4ms 예산을 넘는다. 이번 작업은 입력 지연 개선이나 해당 예산 통과를 주장하지 않는다.

## 잔여 위험과 다음 작업의 검증 기준

이번 변경은 전체 제품의 무결성이나 모든 성능 예산 달성을 증명하지 않는다. 다음 변경은 아래 재현과 검증을 먼저 갖춰야 한다.

1. **입력 경로의 선형 비용.** `presentation.rebased`와 prefix index 재구성이 매 입력마다 전체 스타일 수에 비례한다. 기존 ScaleTests는 문서 스냅샷 복사를 제외하고 문서 끝 입력만 측정했다. 이번에 NSDocument 콜백을 포함한 head/middle/tail 측정을 추가했다. 다음 단계는 1MB/10MB의 allocation/time profile → 영향받은 suffix만 갱신하는 구현 → 임의 UTF-16 편집에 대한 전체 재계산 차등 검사 순서다. 전체 파서를 교체할 근거는 아직 없다.
2. **렌더 이미지의 전체 보유량.** RenderService의 48MiB 제한과 별개로 EditorController.artifacts가 방문한 모든 요소의 CGImage를 붙잡는다. 많은 서로 다른 이미지가 있는 긴 문서를 순회하며 앱과 WebContent 프로세스 메모리를 함께 측정해야 한다. 해결은 원거리 artifact 퇴출과 표시 높이 유지 정책을 함께 설계해야 하며 스크롤 위치·클릭 좌표·재렌더 반복을 검증해야 한다.
3. **긴 컨테이너와 비정상 수식 입력.** 길게 이어진 block quote는 prefix-maximum index의 후보 수를 늘린다. 닫히지 않거나 통화 규칙으로 거부되는 `$`의 반복은 mathSpans 안쪽 탐색을 반복시킬 수 있다. 각각 크기별 adversarial corpus와 기준 결과를 고정한 후 interval index나 수식 스캐너를 변경해야 한다. 이번 긴 줄 벤치마크는 이 두 경우를 측정하지 않는다.
4. **WebKit 실패 수명주기.** navigation timeout 작업과 delegate가 현재 WebView/작업을 식별하는지, snapshot API 대기에도 상한이 있는지 추가 검증이 필요하다. WebContent 강제 종료·timeout 직후 재요청·창 종료·여러 문서·최소화의 재현 시험을 먼저 만들고 요청별 token 및 취소 범위를 보완해야 한다.
5. **파일 시스템과 제품 검증.** 외부 변경 검사는 presenter를 직접 호출한다. OS가 전달하는 이동·삭제·동시 파일 조정, 디스크 부족, 실제 한글 IME 후보창, VoiceOver 탐색, macOS 26 실기, 10MB 편집 UI는 별도 검증 대상이다. 저장 충돌 후 Save As의 이미지 기준 경로 및 복구 기록 갱신도 실제 창 흐름으로 추가 확인할 필요가 있다.
6. **사용자가 보는 지연.** 메인 스레드 호출 시간은 입력→화면 표시 시간과 다르다. 60/120Hz frame time, 입력 중 서식 반영 지연, 실제 cold launch는 Instruments 및 통제된 머신에서 측정해야 한다. 이번 결과로 PLAN.md의 M1 8GB/macOS 26 목표 통과를 선언하지 않는다.

참고한 공개 계약: [Swift의 UTF-8 String 설계](https://www.swift.org/blog/utf8-string/), [Apple markedRange 좌표 정의](https://developer.apple.com/documentation/appkit/nstextinputclient/markedrange()), [NSFilePresenter 변경 알림](https://developer.apple.com/documentation/foundation/nsfilepresenter/presenteditemdidchange()). 이 자료는 API 의미를 확인하는 근거이며 성능 수치는 이 저장소에서 별도로 측정했다.
