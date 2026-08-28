# Apple on-device intelligence in Relay

Audience: Relay maintainers  
Reviewed: 2026-08-27  
Test machine: Apple M3 Max, 64 GB, macOS 26.5.2, Xcode 26.6 / macOS SDK 26.5

## Decision

Relay should use several small, bounded intelligence layers rather than treating every interaction as a generative-model request.

1. Deterministic terminal state remains authoritative: shell integration, command history, current directory, exit status, project markers, agent events, and peer messages.
2. Apple's Foundation Models framework may choose among safe actions and phrase short next-turn prompts. Generated text is never executed automatically.
3. Natural Language sentence embeddings rank agent activity semantically without using a generative model for every search.
4. Core ML personalization should wait until Relay has enough explicit accept/reject feedback to train a useful small ranker.
5. Cloud inference remains a separate future opt-in. The current experimental path is entirely on-device.

## Capabilities that fit Relay

### Foundation Models: use now

Apple exposes an on-device language model with structured guided generation and tool calling. Guided generation constrains output to Swift types, avoiding free-form parsing. The model has a 4,096-token session context, so Relay should provide compact state rather than terminal transcripts. [Foundation Models](https://developer.apple.com/documentation/FoundationModels/) · [Guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation) · [Context limits](https://developer.apple.com/documentation/FoundationModels/generating-content-and-performing-tasks-with-foundation-models)

Relay uses it for:

- selecting `read documentation`, `install dependencies`, `build`, `test`, or `inspect project` from candidates produced by trusted project detection;
- suggesting one short next Codex/Claude question after a structured turn boundary;
- compact summaries of structured agent, subagent, and peer events.

It should not invent arbitrary shell commands. The application supplies the exact command associated with the selected action. Low Power Mode and serious thermal pressure disable generation.

All model requests share one process-wide scheduler. Automatic requests are serialized, rate-limited to at most one start every twenty seconds, skipped while Relay is inactive or the Mac is locked, and never replayed from restored historical events. Interactive experimental suggestions can run sooner but cannot overlap another model request.

`LanguageModelSession.prewarm` can reduce perceived latency when interaction is expected at least a second later, but Apple advises using it only with a strong near-term interaction signal. Relay should consider it after measuring real completion latency; unconditional prewarming would work against the battery objective. [Prewarming sessions](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/prewarm%28promptprefix%3A%29)

### Natural Language embeddings: use now

Apple supplies sentence embeddings and cosine-distance comparison through `NLEmbedding`. This is a direct fit for semantic activity search, grouping similar failures, and matching a query such as “which agent changed the parser?” to structured event summaries. It avoids a generative request and keeps search results deterministic after the embedding distance is computed. [NLEmbedding](https://developer.apple.com/documentation/naturallanguage/nlembedding)

Relay now uses sentence embeddings to refine agent activity search and falls back to the Foundation Models ranker only when the embedding is unavailable.

`NLContextualEmbedding` provides richer token-level contextual vectors, but its assets may need downloading and it is aimed at classification and tagging. It is unnecessary for the current short-query search path. [NLContextualEmbedding](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding)

### Core ML and Neural Engine: revisit after feedback exists

Core ML can route inference across CPU, GPU, and Neural Engine, and supports on-device model updates. A future tiny ranking model could learn from accepted, ignored, and rejected suggestions without uploading that history. [Compute-unit selection](https://developer.apple.com/documentation/coreml/mlcomputeunits) · [On-device personalization](https://developer.apple.com/documentation/coreml/model-personalization)

This is not yet justified. Relay first needs a privacy-preserving feedback store, a minimum sample threshold, evaluation against a non-learning baseline, model versioning, and an easy reset. Until then, rules plus bounded Foundation Models selection are easier to audit and likely more accurate.

Relay now has the feedback layer: it records only accepted/rejected action categories and begins reordering after three observations. This supplies future Core ML training data without committing to a model prematurely.

### Foundation Models custom adapters: investigate, do not ship now

Apple provides a LoRA-based adapter training toolkit that can specialize the system language model. This M3 Max and its 64 GB of memory meet Apple's stated training-machine requirement, but adapters currently have poor product economics for Relay: Apple estimates roughly 100–1,000 examples even for a basic task, each adapter is about 160 MB, every system-model version needs a separately trained adapter, deployment needs a special entitlement, and the final 26.0 toolkit is explicitly incompatible with OS 27 and later. [Foundation Models adapter training](https://developer.apple.com/apple-intelligence/foundation-models-adapter/)

Relay should reconsider an adapter only if a large evaluated dataset shows that bounded prompting and a small Core ML ranker cannot reach acceptable action-selection accuracy.

### Foundation Models tools: useful for an explicit assistant, not background completion

Tool calling can give the local model access to current app data. A future explicit “What should I do here?” action may safely expose read-only tools for project markers, recent command outcomes, structured agent state, peer messages, artifacts, and Git status. Tools that execute commands, edit files, approve agents, or send peer messages must require a visible user action and confirmation. Tool definitions also consume the model's limited context, so Relay's automatic ghost-text path should continue precomputing a small signal set instead. [Foundation Models tool calling](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling)

### Vision: useful for artifacts, not command prediction

Vision can recognize text and document structure in local images. Relay could use this to make screenshots and generated figures searchable, create accessible descriptions, or let an agent reference text visible in an image. It should run only on an opened or explicitly indexed artifact, never continuously over the screen. [RecognizeTextRequest](https://developer.apple.com/documentation/vision/recognizetextrequest) · [RecognizeDocumentsRequest](https://developer.apple.com/documentation/vision/recognizedocumentsrequest)

### App Intents and Spotlight: useful system integration

App Intents can expose Relay actions and entities to Siri, Spotlight, and Shortcuts. Good bounded intents would be “Open pinned session,” “Reconnect node,” “Show agents needing attention,” and “Open project in Relay.” Core Spotlight can index locally stored session metadata, not terminal transcripts. [App Intents](https://developer.apple.com/documentation/appintents) · [Core Spotlight searchable items](https://developer.apple.com/documentation/corespotlight/cssearchableitem)

### GPU and Metal: keep for rendering

The GPU is valuable for terminal composition, image scaling, and effects, but invoking custom GPU inference for small text-ranking tasks would duplicate system frameworks and increase engineering and energy cost. Foundation Models and Core ML should select the available Apple Silicon compute units. Relay should not manually force the GPU for suggestions.

## Adoption matrix

| Apple capability | Relay use | Decision |
| --- | --- | --- |
| Foundation Models guided generation | Choose a bounded next action; phrase short agent prompts; summarize events | Implemented, experimental |
| Natural Language sentence embeddings | Semantic agent and peer-event search | Implemented |
| Private local feedback ranker | Learn accepted versus explicitly rejected action categories | Implemented, resettable |
| Core ML + on-device updates | Personalized action ranking after enough feedback exists | Later, after evaluation data |
| Foundation Models tools | Read-only “What should I do here?” assistant | Later, explicit invocation only |
| Foundation Models custom adapter | Domain-specialized action model | Not now; version and deployment cost is too high |
| App Intents + Spotlight | Open pinned sessions, reconnect nodes, show agents needing attention | Good next system integration |
| Vision OCR/document analysis | Search and describe opened image artifacts | Good opt-in artifact feature |
| Speech | Dictate a prompt or command locally | Optional accessibility feature |
| Metal/custom GPU inference | Terminal rendering and image presentation | Keep rendering only |

## Current next-action flow

1. OSC 7 and shell integration update the active remote directory.
2. After a command finishes, experimental mode lists only cached top-level project entries through relayd.
3. Relay detects documentation and build-system markers locally.
4. It creates a bounded set of safe actions.
5. Apple's on-device content-tagging model chooses one action; deterministic ordering is the fallback.
6. Relay displays the associated complete command or agent prompt as ghost text.
7. Tab inserts it. Relay never presses Enter.
8. Tab acceptance and explicit Escape rejection update a bounded preference score keyed only by coarse project type, agent type, and action category. After three observations it may reorder equally appropriate actions.

The remote listing is cached for five minutes, capped to relevant marker names, times out after four seconds, and is disabled with the experimental setting. Learned feedback never stores paths, commands, prompts, or terminal text and can be reset in Settings. File contents and raw terminal transcripts are not sent to a cloud service.

## Next increments

1. Add confidence suppression: show nothing when deterministic and model rankings disagree strongly.
2. Benchmark time-to-first-suggestion, CPU time, wakeups, and energy impact on battery and AC power.
3. Add App Intents for opening pinned sessions and showing agents that need attention.
4. Add opt-in Vision indexing for opened image artifacts with accessible text extraction.
5. Reconsider a personalized Core ML ranker only after enough feedback and an offline evaluation set exist.
