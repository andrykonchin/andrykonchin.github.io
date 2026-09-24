---
name: blog-post-editor
description: >-
  Use this skill when the user wants to create, draft, review, edit, or
  format a new blog post for this Jekyll site, ensuring proper
  frontmatter, naming conventions, and formatting.
---

# Skill: Review and Edit the Technical Blog Posts

## Purpose

Review, edit, and improve technical blog posts for Andrii Konchyn's personal software-engineering blog.

The goal is **not merely to make articles technically correct or well-written**. The goal is to help produce articles that provide durable value to experienced software engineers in an era where readers can ask an AI assistant to explain almost any established technical topic.

The blog's distinctive perspective comes from the author's experience as:

- an experienced Ruby programmer;
- a long-time backend/web developer;
- a Ruby language expert;
- an implementer of an alternative Ruby VM (TruffleRuby);
- an engineer who has reimplemented Ruby core and standard-library functionality;
- an open-source maintainer and contributor;
- an open-source archaeologist and chronicler of CRuby core team and community development processes, decision-making dynamics, and language governance;
- an engineer interested in language runtimes, VM implementation, operating systems, networking, databases, performance, and debugging.

The blog should make this expertise visible **through investigation and evidence rather than through claims of authority**.

---

## Core Editorial Principle

Prefer:

> "I encountered something interesting while implementing, debugging, or using X, investigated it, and discovered Y."

over:

> "Here is an explanation of X."

The article should ideally contain something that cannot be obtained merely by asking an AI assistant a generic question.

This does **not** mean the information must be completely unknown or impossible for an AI to derive.

A good article can explain something already discoverable from documentation or source code, but should add value through one or more of:

- first-hand experience;
- original investigation;
- experiments;
- source-code archaeology;
- open-source archaeology and governance analysis (uncovering how CRuby core team processes, community debates, and historical constraints shaped Ruby);
- implementation details;
- unexpected observations;
- debugging history;
- comparisons between implementations;
- measurements;
- concrete examples;
- nuanced conclusions;
- connections between different abstraction layers.

The goal is not to make the article "AI-proof." The goal is to make it **worth reading even when the reader has immediate access to AI**.

---

# 1. Review the Article's Core Value First

Before editing prose, identify:

1. What is the central question?
2. Why would an experienced engineer care?
3. What did the author personally discover?
4. What evidence supports the conclusions?
5. What could a capable AI assistant answer immediately?
6. What does this article provide beyond that generic AI answer?

Do **not** start by correcting grammar.

First determine whether the article has a compelling technical core.

If the article is mostly generic information, recommend ways to introduce:

- an investigation;
- an experiment;
- implementation details;
- a surprising observation;
- a real bug;
- a comparison;
- source-code analysis;
- or the author's own experience.

Do not invent experiences, experiments, or conclusions that the author did not actually have.

---

# 2. The AI Substitution Test

For every article, mentally ask:

> "Could a capable AI assistant produce essentially the same article by reading the relevant documentation and source code?"

If the answer is yes, do not automatically reject the article.

Instead identify what can make it substantially better.

Prefer adding one or more of:

### First-hand implementation

> "I implemented this in TruffleRuby and encountered..."

### First-hand debugging

> "I encountered this bug and initially suspected X. The actual cause was Y."

### Experiment

> "I expected X, so I constructed an experiment to test it."

### Measurement

> "Here are the actual benchmark, profiling, memory, or system-call results."

### Source archaeology

> "Following this behavior through the implementation reveals..."

### Cross-implementation comparison

> "CRuby does X while TruffleRuby does Y, because..."

### Unexpected consequence

> "This apparently simple API has this surprising property..."

### Historical or design explanation

> "This behavior makes more sense once we understand why it was designed this way."

### Open-source archaeology and core-team dynamics

> "Excavating the multi-year history of this ticket, debate, or commit reveals why the CRuby core team made this choice, how community friction shaped it, and what it teaches about open-source language development."

---

# 3. Preferred Article Archetypes

Encourage these forms of articles.

## A. Implementation Investigation

A strong structure is:

1. I needed to implement or understand X.
2. I expected it to work in a particular way.
3. I investigated CRuby, a library, the OS, or relevant source code.
4. I discovered something unexpected.
5. Here is how the implementation actually works.
6. Here is why it works that way.
7. Here is how I implemented or worked around it.
8. Here are the implications.

For example:

> Implementing `File#birthtime` in TruffleRuby

The article should not merely document CRuby's implementation.

It should explain what implementing the method revealed about platform-specific filesystem APIs and Ruby's abstraction over them.

---

## B. Source-Code Archaeology

Start from observable behavior and trace it into the implementation.

A useful conceptual path is:

```text
Ruby program
    ↓
Ruby API
    ↓
library
    ↓
VM/runtime
    ↓
native implementation
    ↓
OS abstraction
    ↓
system call
```

Explain only the portions necessary to answer the question.

Avoid turning the article into a source-code dump.

---

## C. Debugging / Postmortem

A strong structure is:

```text
Symptom
↓
Minimal reproduction
↓
Initial hypothesis
↓
Investigation
↓
False lead(s)
↓
Root cause
↓
Fix
↓
Why existing tests didn't catch it
↓
Lessons
```

Do not automatically remove false leads merely because they make the article less concise.

A debugging path can be one of the most valuable parts of the article because it demonstrates engineering reasoning.

---

## D. Experiment

A strong structure is:

```text
Question
↓
Hypothesis
↓
Experimental setup
↓
Result
↓
Unexpected result
↓
New hypothesis
↓
Second experiment
↓
Conclusion
```

Include enough information for technically capable readers to reproduce the experiment.

Distinguish clearly between:

- observed result;
- interpretation;
- hypothesis;
- established fact.

---

## E. Cross-Implementation Comparison

This is particularly valuable when discussing:

- CRuby vs TruffleRuby;
- CRuby vs JRuby where relevant;
- Ruby semantics vs implementation details;
- Ruby runtime vs operating system;
- Ruby library vs underlying network/database system.

Always distinguish:

> behavior required by Ruby semantics

from:

> behavior that happens to be an implementation detail of CRuby.

This distinction is especially important when discussing compatibility.

---

## F. Open-Source Archaeology & Language Governance

This archetype excavates the human, organizational, and technical processes of open-source development within the CRuby core team and the broader Ruby ecosystem.

A strong structure is:

```text
Observable quirk, controversy, or long-standing problem
↓
Unearthing the buried history (Redmine tickets, mailing lists, commit logs, Bugzillas)
↓
Competing technical and philosophical positions (Core team vs community / practitioners)
↓
Systemic blockers (outdated upstream docs, monolithic stdlib, backward compatibility)
↓
Turning point or resolution (how consensus formed or alternative gems forced the issue)
↓
Governance lessons for open-source language development
```

Crucial guidelines for this archetype:

- **Distinguish engineering archaeology from forum gossip:** Do not write superficial summaries of heated arguments. Frame the story as an engineering and governance case study that analyzes why capable engineers disagreed and how systemic constraints influenced the outcome.
- **Surface buried primary sources:** Synthesize multi-year Redmine threads, obscure bugzillas, and cross-repo commits that readers would never find or have time to parse on their own.
- **Analyze systemic failure modes:** Highlight anti-patterns such as documentation dogmatism (e.g., relying on outdated man pages over operational reality), the cost of bundling libraries into monolithic stdlibs, and communication gaps between runtime maintainers and systems programmers.
- **Connect past decisions to modern Ruby:** Explain how historical controversies directly produced modern features, architectural splits, or stdlib gemification.

---

# 4. Look for Surprising Questions

Strong posts often originate from questions such as:

- Why does Ruby behave this way?
- Why did this take years to resolve in CRuby despite obvious community demand?
- How did the decision-making process in the core team shape this API or architecture?
- What systemic or governance constraint (e.g., outdated documentation, stdlib bundling) blocked the obvious fix?
- Why is this apparently simple method implemented this way?
- Why does this only happen on one platform?
- Why does this work in CRuby but differently in another implementation?
- What happens underneath this familiar API?
- What does Ruby actually guarantee here?
- Is this behavior specified or accidental?
- Why does this library need such complicated code?
- Why didn't the existing tests catch this?
- What happens if I remove or change this implementation detail?
- What happens at the boundary between Ruby and the OS?

When reviewing an article, actively search for opportunities to expose such questions.

---

# 5. Prefer Evidence Over Authority

Do not write:

> "Ruby internally does X."

when the article can instead show:

> "We can see X by running this experiment..."

or:

> "Following the call from `foo` leads to `bar` in CRuby..."

or:

> "I verified this with the following test..."

The author's expertise should be demonstrated by the quality of the investigation.

Avoid unnecessary phrases such as:

- "As a Ruby expert..."
- "Obviously..."
- "It is well known..."
- "Everyone knows..."
- "The correct implementation is..."

Use evidence instead.

---

# 6. Preserve the Author's Personal Voice

The writing should feel like an experienced engineer explaining something they genuinely investigated.

Preserve first-person narration when it contributes to the story:

- "I expected..."
- "I was surprised to discover..."
- "I initially thought..."
- "I tried..."
- "I couldn't explain this behavior until..."
- "When implementing this in TruffleRuby..."
- "Looking at CRuby's source revealed..."

Do not turn the article into an impersonal textbook.

Do not make the writing artificially polished at the cost of personality.

---

# 7. Technical Depth

The intended audience is primarily technically strong software engineers.

Do not oversimplify interesting implementation details merely to make the article accessible.

However:

- introduce unfamiliar concepts before relying on them;
- explain why a detail matters;
- avoid unexplained implementation jargon;
- don't include source-code details that don't advance the argument.

The target level is:

> accessible to a strong Ruby/backend engineer, while still interesting to runtime/VM engineers.

---

# 8. Ruby Semantics and Implementation Review

When reviewing a Ruby article, pay particular attention to claims involving Ruby's subtle or easily misunderstood behavior.

Do not assume that code that looks intuitive behaves intuitively. Verify claims against Ruby's actual semantics, and distinguish language-level behavior from implementation details.

Relevant areas include:

- parser behavior and parsing ambiguities;
- operator precedence and syntax;
- blocks, `yield`, procs, and lambdas;
- method lookup, singleton classes, `include`, `prepend`, and `method_missing`;
- constant lookup and lexical scope;
- `class_eval`, `instance_eval`, and `instance_exec`;
- refinements and other metaprogramming features;
- exceptions, `ensure`, and non-local control flow;
- `require`, `load`, and feature loading;
- threads, fibers, and concurrency semantics;
- object allocation and garbage collection;
- `String`, bytes, encodings, and transcoding;
- `IO`, `File`, and filesystem behavior;
- native extensions and the Ruby C API;
- VM, JIT, and runtime behavior.

For each significant technical claim, determine which of the following it describes:

1. **Ruby language semantics** - behavior that Ruby implementations are expected to provide.
2. **Observable behavior** - behavior that Ruby programs can rely on, even if it is not necessarily a formal language guarantee.
3. **CRuby implementation detail** - behavior specific to MRI/CRuby.
4. **TruffleRuby implementation detail** - behavior specific to TruffleRuby.
5. **Platform behavior** - behavior originating from the OS, filesystem, libc, compiler, CPU, or another underlying system.

Flag claims that incorrectly present an implementation detail as a Ruby language rule.

When the distinction matters, suggest explicitly stating which layer the article is describing.

### Version Grounding & Reproducibility

- **Version Pinning:** Always state the target Ruby version (e.g., Ruby 2.7, 3.2) and relevant library/gem versions (e.g., `rubocop-minitest v0.8.0`, `parser 3.1`) when quoting AST node shapes, parser behavior, or benchmark numbers, as internal representations change over time.
- **Standalone Reproducers:** When discussing AST patterns, runtime quirks, or language mechanics, include a minimal standalone script (e.g., using `ProcessedSource.new` or a short self-contained Ruby snippet) so the reader can reproduce and verify the behavior immediately in IRB without configuring a full test harness.

Do not exhaustively investigate every item in this list for every Ruby article. Focus on the areas that are actually relevant to the article's claims and examples.

The purpose of this review is to prevent subtle technical inaccuracies and to make the distinction between **Ruby semantics, implementation behavior, and platform behavior** clear to the reader.

---

# 9. Claims and Verification

Flag claims that require verification.

Especially flag:

- claims about CRuby internals;
- claims about system calls;
- claims about OS behavior;
- claims about thread safety;
- claims about atomicity;
- performance claims;
- benchmark conclusions;
- memory usage;
- compatibility claims;
- historical claims;
- claims about what Ruby "guarantees."

When possible, recommend verifying them against:

1. actual source code;
2. executable experiments;
3. tests;
4. official documentation;
5. relevant standards;
6. multiple Ruby implementations.

### Open-Source and Community Attribution

When discussing bug fixes, contributions, or open-source investigations:

- **Link Canonical Artifacts:** Always link directly to relevant GitHub pull requests, issues, commits, and source code files.
- **Explicit Attribution:** Credit maintainers, issue reporters, and collaborators by name and GitHub handle (e.g., Yasuo Honda (`@yahonda`), Koichi Ito (`@koic`)) rather than using vague references (*"a maintainer noticed..."*).

Do not silently invent missing details.

If the article contains an uncertain claim, explicitly mark it for author verification.

---

# 10. Experiments and Benchmarks

When an article makes an empirical claim, ask:

- Can this be demonstrated?
- Is there a minimal reproduction?
- Are the relevant variables controlled?
- Is the benchmark methodology explained?
- Is the result being overgeneralized?
- Is the sample size sufficient?
- Could the result depend on Ruby version, OS, CPU, compiler, or configuration?

Do not let a benchmark become decorative.

Every measurement should support an argument.

---

# 11. Source Code

Source snippets should be:

- minimal;
- directly relevant;
- annotated when necessary;
- linked to the original source when appropriate;
- accompanied by an explanation of why the code matters.

Do not reproduce large sections of upstream source merely to demonstrate that they exist.

Prefer:

> "This call eventually reaches X."

Then show the small portion necessary to understand the mechanism.

---

# 12. Structure

A strong technical article usually needs:

### Opening & Post Excerpt

Start with the question, problem, or surprising observation.

**First Paragraph as Post Excerpt:**
The first paragraph of every post is used by Jekyll as `{{ post.excerpt }}` on the blog's index page (`index.html`) to display the post summary in the article list. It represents the entire post to prospective readers. Therefore, the first paragraph must:
- be completely self-contained and descriptive;
- provide enough context and substance to give the reader an accurate understanding of what problem is tackled, what is investigated, and what the post covers;
- avoid relying on subsequent sentences, headings, or immediate code blocks to make sense on its own.

Avoid generic introductions such as:

> "Ruby is a popular programming language..."

### Investigation

Show how the answer was discovered.

### Explanation

Give the conceptual model.

### Evidence

Use source code, experiments, traces, tests, or measurements.

### Implications

Explain why the discovery matters.

### Conclusion

State the main lesson concisely.

Do not add a generic "In conclusion, we learned..." section unless it genuinely helps.

---

# 13. Editing Style

Correct:

- grammar;
- spelling;
- awkward phrasing;
- unclear sentences;
- repetition;
- inconsistent terminology;
- poor transitions.

Prefer:

- concise sentences;
- precise technical terminology;
- concrete examples;
- active voice;
- natural first-person narration.

Avoid:

- corporate language;
- marketing language;
- excessive headings;
- generic filler;
- exaggerated claims;
- motivational conclusions;
- unnecessary definitions of basic programming concepts;
- AI-sounding prose;
- excessive bold formatting across paragraphs;
- bold-leading list items (e.g., `- **Key Concept:** explanation...`);
- em dashes (`—`) or en dashes (`–`).

### Typography and Formatting Rules

- **Hyphens Only:** Always use regular ASCII hyphens (`-` or ` - ` for parenthetical breaks). Never use em dashes (`—`) or en dashes (`–`).
- **Restrained Bold Usage & Prefer Italics:** Do not use bold text for casual emphasis or to start bullet list items. Let lists and sentences read naturally without artificial bold callouts. When emphasis is genuinely needed within prose, prefer italics (`*text*`) rather than bold (`**text**`), as bold text visually disrupts the natural reading flow.

### Translation & Localization

When reviewing or editing translated posts (e.g., from Russian to English):

- **Natural English Engineering Idiom:** Do not translate sentences or Russian idioms literally. Restructure sentences into natural, idiomatic English with clear subject-verb agreement and active voice.
- **Canonical Terminology:** Use standard Ruby and systems terminology (e.g., "monkey-patching", "allowlist", "arity", "node matcher", "receiver", "call site") rather than literal translations.
- **Canonical English Sources:** Replace references to Russian-language articles, forum posts, or translations with canonical English documentation, official GitHub repositories, PRs, or specs.

Do not rewrite the author's style into generic polished technical prose.

When a sentence is technically correct but stylistically unusual, preserve it unless there is a clear reason to change it.

---

# 14. Avoid AI Writing Smells

Flag and remove patterns such as:

- "In today's rapidly evolving technological landscape..."
- "Let's dive into..."
- "It's important to note that..."
- "This powerful feature..."
- "As you can see..."
- repetitive conclusion sections;
- redundant recap tables or cheat-sheet matrices that merely duplicate facts or conclusions already clearly explained in the body prose;
- textbook-style summary sections that summarize what the reader just read without providing new analysis;
- artificial enthusiasm;
- excessive bullet lists;
- bold-leading bullet points on every list item (`- **Title:** description...`);
- generic summaries that add no information;
- claims that something is "revolutionary", "elegant", or "powerful" without technical justification.

The article should sound like an engineer writing for other engineers.

### Tables and Reference Matrices

Use tables only when data is genuinely difficult to parse in prose (such as multi-variable benchmark results, profiling metrics, or complex configuration options).

Do not add summary tables merely to "recap" a narrative investigation. When the text already walks the reader through each platform or mechanism, repeating those points in a table creates mechanical redundancy and makes the post feel like an AI-generated textbook.

---

# 15. Title Guidelines

Prefer titles that expose a question, surprise, investigation, or concrete experience.

Good patterns:

- "Implementing X in TruffleRuby"
- "What I Learned Implementing X"
- "Why X Is More Complicated Than It Looks"
- "I Expected X, But Ruby Does Y"
- "How X Actually Works"
- "Following X Through CRuby"
- "The Strange Case of X"
- "Why X Breaks Under Y"
- "What CRuby's Implementation of X Reveals About Ruby"

Avoid generic SEO titles such as:

> "Complete Guide to X"

> "Everything You Need to Know About X"

> "10 Things About X Every Developer Should Know"

unless the article genuinely deserves that format.

---

# 16. The "Would I Read This?" Test

Before finalizing an article, evaluate it from three perspectives.

### Ruby developer

Would an experienced Ruby developer learn something useful or surprising?

### Runtime engineer

Would someone interested in language implementations find a technically interesting detail?

### Open-source practitioner or systems architect

Does this article illuminate how real-world decisions, trade-offs, and governance dynamics unfold within the CRuby core team and open-source ecosystem?

### Future author

Does this article demonstrate the author's engineering ability and experience?

A strong post should satisfy at least two of these, ideally all four.

---

# 17. Recommended Review Output

When reviewing a draft, produce the following sections.

## 1. Overall assessment

Briefly state:

- what the article is about;
- its strongest aspect;
- its biggest weakness;
- whether it is worth publishing.

## 2. AI-value assessment

Explain:

> What could an AI assistant already answer about this topic?

Then:

> What makes this article more valuable than that answer?

If the second answer is weak, recommend concrete additions.

## 3. Technical issues

List:

- incorrect claims;
- questionable claims;
- missing nuance;
- implementation/semantic confusion;
- unsupported conclusions.

Separate confirmed problems from things requiring verification.

## 4. Content opportunities

Suggest specific places where the author could add:

- experiments;
- source-code investigation;
- measurements;
- implementation details;
- surprising observations;
- comparisons;
- lessons.

Do not invent experiences that the author did not mention.

## 5. Structure

Recommend changes to:

- opening;
- ordering;
- section boundaries;
- conclusion;
- title.

## 6. Line editing

Perform the actual prose edit.

Preserve the author's voice and technical depth.

Do not substantially rewrite technically sound content merely for stylistic preference.

## 7. Opportunities to shorten the text

After completing the line edit, conduct an explicit pass to identify opportunities to tighten and shorten the post without sacrificing technical depth or voice:

- pinpoint mechanical redundancy (repetitive identical code blocks or re-quoting unchanged code without pedagogical reason);
- distinguish didactic duplication from mechanical duplication (keep step-by-step 1-line breakdowns that guide the reader through method execution, but eliminate identical copies of whole blocks);
- identify conceptual restatements already explained in earlier sections;
- spot text that duplicates information conveyed by diagrams or code;
- scrutinize tables and comparison matrices: determine whether each table presents necessary structured data or merely duplicates facts already narrated in the prose;
- prune overly verbose introductions or preambles before scripts and examples.

Present these candidates clearly with before-and-after comparisons and estimated line savings so the author can choose which to apply.

## 8. Final verdict

Classify the post as one of:

- **Publish as-is**
- **Publish after minor editing**
- **Worthwhile but needs deeper investigation**
- **Technically useful but too generic**
- **Needs a stronger central idea**

Explain the verdict briefly.

---

# 18. Most Important Rule

Never optimize the article merely to maximize the amount of information it contains.

Optimize for:

> **interesting question + first-hand investigation + evidence + technical insight + clear explanation**

A 1,500-word article containing an unusual discovery from real engineering work is preferable to a 5,000-word comprehensive explanation that an AI assistant could generate from documentation.

The blog should ultimately communicate:

> **"This is what an experienced engineer discovered by actually working on Ruby and software systems."**

The author's expertise should emerge naturally from the investigation, not from repeatedly stating that the author is an expert.

---

# 19. Jekyll & Repository Specifications

When creating, editing, or formatting blog posts for this repository, adhere strictly to these technical requirements:

## File Location & Naming
- Store posts in `_posts/` with the naming scheme:
  ```text
  _posts/YYYY-MM-DD-<slug>.markdown
  ```
- The slug should be lowercase and hyphen-separated (e.g., `_posts/2026-08-14-file-birthtime-ruby-method-implementation.markdown`).

## Frontmatter Schema
Every post must include YAML frontmatter matching this layout:
```yaml
---
layout: post
title:  "Your Descriptive Title"
date:   YYYY-MM-DD HH:MM
categories: Ruby
---
```
- `layout`: Always set to `post`.
- `title`: Follow Section 15 title guidelines (avoid generic SEO titles).
- `date`: Timestamp in `YYYY-MM-DD HH:MM` format.
- `categories`: Topic category (e.g., `Ruby`, `TruffleRuby`, `Performance`, `Algorithms`, `Testing`).

## Markdown & Code Highlighting
- Engine is **kramdown** with **rouge** syntax highlighting.
- Use standard fenced code blocks with language identifiers (e.g., `ruby`, `c`, `bash`, `text`, `yaml`, `diff`).
- Keep code snippets focused and minimal (refer to Section 11).

## Excerpts & Index Page
- Jekyll automatically extracts the first paragraph (up to the first empty line) as `{{ post.excerpt }}` to display in the post list on `index.html`.
- Ensure the opening paragraph is self-contained, descriptive, and long enough to serve as an enticing, standalone synopsis of the entire post on the homepage.

## Images & Visual Assets
- Store images in `assets/images/<slug>/` matching the post's slug.
- **ASCII-Only Paths:** Ensure all image directories and filenames contain strictly ASCII characters (verify there are no lookalike Unicode/Cyrillic characters).
- **Prose-to-Diagram Balance:** When an SVG diagram visually maps node relationships or architecture, let the diagram communicate the mapping and avoid repeating identical textual bullet lists in the prose.
- **Prototyping:** During initial drafting, use Mermaid or clean ASCII diagrams to structure and iterate on visuals before producing final SVG graphics.

---

# 20. Verification Checklist & Local Preview

Before finalizing a draft, review, or edit, walk through this checklist:

## Pre-Publication Checklist
1. **Frontmatter**: Valid `layout`, `title`, `date`, and `categories` present.
2. **File Path**: Matches `_posts/YYYY-MM-DD-<slug>.markdown`.
3. **Syntax Highlighting**: All code blocks have explicit language tags.
4. **Attribution of Claims**: Clear distinction between Ruby language semantics, CRuby implementation details, and OS/platform system calls.
5. **No AI Smells**: Checked against Section 14 (no filler, artificial enthusiasm, or generic conclusions).
6. **Core Value**: Satisfies Section 2 (*The AI Substitution Test*) with original evidence, measurements, or implementation insight.
7. **Typography & Formatting**: Uses regular ASCII hyphens (`-`) instead of em/en dashes, avoids excessive bolding in paragraphs and lists, and prefers italics over bold when emphasis is needed.
8. **First Paragraph (Index Excerpt)**: The opening paragraph is completely self-contained, sufficiently informative, and able to represent the whole post on the homepage index list (`post.excerpt`).
9. **Tightening Pass**: Conducted an explicit post-editing pass to identify and eliminate mechanical code duplication, repetitive conceptual recaps, or text duplicating diagrams (while preserving didactic step-by-step breakdowns).
10. **Images & Assets**: Stored in `assets/images/<slug>/` with strictly ASCII paths, referencing diagrams naturally without redundant textual bullet lists.
11. **Attribution & Version Pinning**: Credited open-source maintainers/collaborators with direct links, and explicitly stated target Ruby and library versions for AST, parser, or runtime mechanics.
12. **Translation Quality (if applicable)**: Ensured translated text reads as natural, idiomatic English engineering prose without Russian-language idioms or sentence structures, linking to canonical English documentation.

## Local Preview
When testing or building the site locally:
- Build the site:
  ```bash
  bundle exec jekyll build
  ```
- Run the local development server:
  ```bash
  bundle exec jekyll serve
  ```

