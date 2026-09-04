# 프로젝트 문서

이 디렉터리는 프로젝트의 설계 검토, 요구사항, 구현 계획과 장기 보존할 결정을 관리한다.

## 카테고리

| 카테고리 | 답하는 질문 |
| --- | --- |
| [`brainstorm`](./brainstorm/README.md) | 결정 전에 무엇을 검토하는가? |
| [`spec`](./spec/README.md) | 합의된 요구사항은 무엇인가? |
| [`plan`](./plan/README.md) | 어떤 순서로 구현하는가? |
| [`retro`](./retro/README.md) | 일정 기간에 무엇을 배웠는가? |
| [`adr`](./adr/README.md) | 무엇을 왜 선택했는가? |
| [`reference`](./reference/README.md) | 가져온 사실은 무엇인가? |
| [`conventions`](./conventions/README.md) | 반복해서 적용할 프로젝트 규칙은 무엇인가? |

## frontmatter 필드

모든 카테고리 문서는 다음 공통 필드를 사용한다.

| 필드 | 필수 | 형식 | 설명 |
| --- | --- | --- | --- |
| `type` | 예 | `brainstorm`, `spec`, `plan`, `retro`, `adr`, `reference`, `conventions` | 문서 카테고리 |
| `title` | 예 | 문자열 | 문서 제목 |
| `created` | 예 | `YYYY-MM-DD` | 최초 작성일 |
| `updated` | 예 | `YYYY-MM-DD` | 마지막 갱신일 |
| `related` | 아니요 | repository root 기준 경로 목록 | 관련 문서 |
| `status` | 조건부 | 카테고리별 값 | `spec`, `plan`, `adr`에서만 사용 |

`status` 값은 다음 범위로 제한한다.

- `spec`: `draft`, `active`, `deprecated`
- `plan`: `planned`, `in-progress`, `completed`, `cancelled`
- `adr`: `proposed`, `accepted`, `rejected`, `superseded`

Markdown 링크는 현재 문서 기준 상대경로를 사용한다. frontmatter와 본문에서 코드로 표시하는 문서 경로는 repository root 기준 경로를 사용한다.
