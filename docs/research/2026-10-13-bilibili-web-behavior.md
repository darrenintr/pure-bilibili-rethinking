# Bilibili homepage and video behavior — REA evidence

Captured 2026-10-13 with REA browser scenarios against bilibili.com. The purpose of this note is to separate what the browser actually showed from what can only be inferred, then map both to Paladala's current implementation.

## Capture setup

- Fresh isolated Chromium 155.0.8059.40 profile, no cookies or browser storage seeded; 1280 × 720 viewport.
- Homepage: open `/`, wait 8 seconds, capture page DOM, accessibility tree, screenshot, URL, and network event metadata.
- Video: open `/video/BV1hrWF6mE1m`, wait 10 seconds, capture the same artifacts.
- Comments: open the same video, click `#commentapp`, wait 8 seconds, capture DOM, accessibility tree, URL, and network event metadata.
- Profile follow-up: open the public creator page linked from the video (`/space/44748304`), wait 10 seconds, and capture DOM/accessibility plus request paths, query-parameter names, and statuses.
- Request and response bodies and header values were disabled. The capture records endpoint paths and HTTP status, not API payloads. No like, favorite, coin, share, or comment submission was attempted.

REA marked all three scenarios complete and the observations as `observed` under `controlled-replay`. “Complete” means the declared capture finished; it does not mean every site state or account behavior was explored. REA also notes that event receipt order does not prove causality and browser events do not expose request initiator stacks ([scenario contract](https://github.com/morluto/rea/blob/main/docs/browser-scenario-contract.md)).

## Evidence index

| Scenario | REA Evidence ID | What it contains |
|---|---|---|
| Homepage | `ev_e6e0fbde2e943bc4b099e644208308c3637b3a4caaeb3a8789eb894eeeea9ab1` | Homepage DOM/accessibility/screenshot and network event metadata after the initial load. |
| Video page | `ev_102dfa260761de50a4490751370196c36620aa13f19408ea3acb91911c73d32a` | Player page DOM/accessibility/screenshot and network event metadata. |
| Comments | `ev_e5a492412ce711384382683e1366465c2e1347b5214c04a95aff075cd1b97f7e` | DOM/accessibility and network event metadata after navigating to the comments section. |
| Creator profile | `ev_c00acbd221f5c78d00ecd3300cf67e5c715d12727825f1d6b871b889b6fe5dbe` | Public profile DOM/accessibility and network request metadata. |
| Direct endpoint check | `ev_e16e2e3fadc96c478416d472b6b0ced53d31ba5943df1b8655a49489878d989c` | A direct top-level navigation to `/x/space/navnum`; Bilibili returned HTTP 412, so this is recorded as a context limitation, not evidence the profile XHR endpoint is retired. |

## What the browser showed

### Homepage suggestions

The homepage rendered recommendation cards in the first viewport. The first captured card linked to `BV1hrWF6mE1m`; its visible metadata included about 59.8K views, 143 danmaku, and a 4:11 duration. The same video opened in the second scenario.

The 8-second homepage network log contains the page request and several navigation/configuration requests, but no recommendation-feed endpoint. **Inference:** the initial cards may have arrived in the page's server-rendered or embedded data. This capture cannot identify their payload source because response bodies were not retained; it also does not establish whether later refreshes use a separate feed request.

### Video loading and playback

The video page showed the title “我问你话呢回答我”, a 4:11 duration, a running player time near 00:13, and a login/preview overlay in the anonymous session. The page DOM included player bootstrap data. The network log recorded HTTP 200 responses for `/x/player/wbi/v2`, `/x/v2/dm/web/view`, `/x/v2/dm/wbi/web/seg.so`, `/x/web-interface/view/cards`, and `/x/web-interface/view/conclusion/judge`.

The browser also fetched `.m4s` media from Bilibili's video CDN using HTTP 206 partial-content responses, consistent with range-based media delivery. Signed CDN query strings are intentionally omitted here.

### Danmaku

The video scenario recorded successful requests to `/x/v2/dm/web/view` and `/x/v2/dm/wbi/web/seg.so`. This is direct evidence that the web player loaded danmaku metadata and a segment for this video. Since response bodies were disabled, the capture does not show the returned protobuf/XML structure, segment timing, or the web player's full scheduling algorithm.

### Comments

After clicking `#commentapp`, the page showed a total of 340 comments and “most popular” / “latest” sort controls. The anonymous page also showed a login prompt for fuller comment access/actions. The capture recorded HTTP 200 responses from `/x/v2/reply/subject/description` and `/x/v2/reply/wbi/main` during this step. No comment was submitted.

### Creator profile requests

The public profile capture recorded HTTP 200 responses for `/x/space/navnum`, `/x/space/wbi/acc/relation`, `/x/space/wbi/acc/info`, `/x/relation/stat`, and `/x/space/upstat`. The profile's `/x/space/wbi/arc/search` request returned HTTP 412 once in this anonymous controlled browser session. That single response does not establish that the route is obsolete; Paladala's shared GET helper already backs off and retries once on 412/429.

The successful `/x/space/navnum` request had a `mid` query parameter. Current API reference material documents that route and lists the dynamic count under `upos`, while its sample response uses `opus`; Paladala's decoder accepts `opus`, `upos`, and the old `dynamic_count` field to tolerate that shape drift ([profile count endpoint reference](https://github.com/Nek0Neko/bilibili-API-collect-arc/blob/main/docs/user/status_number.md)).

The successful relation request carried `mid` plus WBI fields. The current relation reference describes `be_relation` as the current viewer's relationship to the viewed account, with attribute values `2` (followed), `6` (mutual follow), and `128` (blocked) ([relation endpoint reference](https://github.com/realysy/bili-apis/blob/master/docs/user/relation.md)). The response body was not captured, so the status mapping is based on that reference, while the live page capture establishes that the route is used and returned HTTP 200.

### Separate video counters

The video screenshot showed separate like, coin, favorite, and share actions with counts of 5,011, 1,330, 903, and 202. The captured page metadata separately listed 5,054 likes, 1,340 coins, 906 favorites, and 203 shares, alongside about 59.8K views, 143 danmaku, and 340 comments. The visible values are not perfectly synchronized with the page metadata, so treat these as a snapshot of distinct counter categories, not stable totals.

## Mapping to Paladala

| Feature | Existing Paladala path | Change in this work |
|---|---|---|
| Home suggestions | `PaladalaRepository.feed` calls the web recommendation client; `BilibiliAPIClient.recommendedVideos` uses `/x/web-interface/wbi/index/top/feed/rcmd`. Home cards show view, danmaku, and reply counts. | No duplicate feed implementation was needed; this flow already exists. |
| Video details and playback | `videoDetail` fetches `/x/web-interface/view`; `playbackURL` requests `/x/player/wbi/playurl`. The repository joins detail and playback loading; the app's local HLS proxy adapts DASH sources for AVPlayer. | Existing fetching flow retained. |
| Comments | `CommentRepository` coordinates endpoint fallbacks and cursor-based page loading; the repository resolves the video's `aid` before fetching replies. | Existing comments and pagination flow retained. |
| Danmaku | The web player returned 200 for `/x/v2/dm/web/view` and `/x/v2/dm/wbi/web/seg.so`; Paladala previously fetched `comment.bilibili.com/{cid}.xml`. | Replaced XML with WBI-signed six-minute protobuf segments, decoded with a bounds-checked local wire reader, and fetches enough segments for the video's duration. When a later segment fails, earlier segments remain available. The endpoint reference describes `DmSegMobileReply.elems`, `DanmakuElem` fields, and six-minute segmenting ([danmaku API reference](https://github.com/BACNext/bilibili-API-collect-backup/blob/master/docs/danmaku/danmaku_proto.md), [protobuf schema](https://github.com/Janson20/bilibili-api-collect-mirror/blob/master/grpc_api/bilibili/community/service/dm/v1/dm.proto)). |
| Profile dynamic count | Paladala called the retired `/x/space/nav/num` and suppressed HTTP failures as zero. | Replaced it with the profile page's observed `/x/space/navnum`; decode tolerates `opus`, `upos`, and the previous `dynamic_count` field. |
| Follow state | Paladala read `/x/relation` with both target and viewer ids. | Replaced it with the profile page's observed WBI route `/x/space/wbi/acc/relation`; read `be_relation` and corrected relationship attributes. |
| Profile follower/following stats | The app uses `/x/relation/stat`. | Kept the endpoint because the current profile capture returned HTTP 200 for it. |
| Video statistics | `VideoDTO` decoded views, danmaku, likes, and replies; other action counters were dropped. `VideoStatsDTO` could also mislabel a favorite/collect count as likes. | Added optional favorite/coin/share counters, corrected the like mapping, propagated stats through detail, history, favorites, watch-later, and dynamic-video models, and added a separate action-metrics row on the detail screen. |

The resulting detail screen keeps consumption metrics (views, danmaku, replies, duration) separate from engagement metrics (likes, coins, favorites, shares). Optional counters are hidden when the API shape omits them rather than displaying false zeros.

## Limits

- These observations describe one anonymous desktop session and one video on 2026-10-13. Personalized recommendations and signed-in playback/comment behavior were not captured.
- HTTP bodies were not captured for the homepage, video, comments, or profile page captures, so those observations prove the listed requests and statuses, not their response fields. The separate direct-navnum check captured only a 412 security page and is not used to infer response fields.
- A homepage recommendation endpoint was not observed during the short initial-load window; that is not proof the endpoint is never used.
- The danmaku browser capture used a 4:11 video, so it directly observed only a first segment. Six-minute segment boundaries and protobuf fields come from the linked API reference/schema; longer-video segment fetching is implemented from those definitions and was not runtime-tested here.
- The direct navigation to `/x/space/navnum` received 412, while the same route returned 200 as a profile-page request. The direct-navigation result is not used as evidence against the route.
