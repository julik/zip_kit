# Contributing to zip_kit

Contributions are welcome! Please take a moment to review this document so that
contributing stays easy and effective for everyone involved.

I'd especially love to get:

* Reports of archives that a specific unarchiver refuses to open or extracts incorrectly
* Performance work
* Documentation fixes

## What do I need to know to help?

If you would like to learn more about the technologies zip_kit builds on, check out the (non-exhaustive) list below. You can also get in touch with me via an issue or email.

 - [ruby](https://ruby-doc.org)
 - [ZIP files](https://en.wikipedia.org/wiki/Zip_(file_format)) and the [APPNOTE.TXT](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT) specification
 - [rubyzip](https://github.com/rubyzip/rubyzip), as we like to test "our implementation against theirs"
 - [minitest](https://github.com/minitest/minitest) for testing

## Issues and pull requests

* Opening an issue first is often the fastest way to get something in. I can shape it into something that fits the library. Please do this before any significant PR (new features, refactoring), so you don't spend time on something that won't be merged.
* Search the issues first, and check whether the problem still happens on the latest `main`.
* The most useful bug report is a small script that produces the broken archive (or the archive itself), plus the name, version and OS of the tool that fails to open it.
* I may close a PR and implement the idea differently. That's not a rejection of the idea, and you'll be credited (`Co-authored-by`).
* Feel free to propose opinionated changes, but be prepared that your opinion won't be shared. It is a give-and-take.
* Keep PRs focused, without unrelated commits.

## Code changes

Please adhere to the coding conventions used throughout the project (indentation,
accurate and terse comments, etc.) and any other requirements (such as test coverage).

Run the `rake` default task before submitting. It runs the test suite (`bundle exec rake test`),
checks formatting with [standard](https://github.com/standardrb/standard) (`bundle exec rake format`
fixes most of it), and regenerates the type signatures in `rbi/`. Commit the regenerated signatures.

The tests run in parallel, in one forked process per CPU core. Set `TEST_WORKERS=1` to run them in a single
process, and `SEED=1234` to repeat the order of a particular run. A test which measures timings should be
declared with `parallel: false`, so that it runs after the others are done.

zip_kit supports Ruby 2.6 and up, and CI runs the tests and the linter on 2.6. Don't use syntax or
stdlib features newer than that. CI also runs the suite with frozen string literals enforced, so don't
mutate string literals.

## Basic expectations

This project is something created with love, and I - as an author - expect you, as a contributor, to return the favor. The ground rules:

* Do your best to be kind.
* Be polite and direct. No abrasiveness, no passive-aggression.
* [Low-context](https://www.ebsco.com/research-starters/communication-and-mass-media/high-context-and-low-context-cultures) communication is preferred and permitted
* No ad-hominems, also in code comments
* No sexualized or aggressive language

These rules sit alongside the [Code of Conduct](CODE_OF_CONDUCT.md), which applies to everyone taking part in the project.

As a maintainer, I reserve the right to deny any contribution, discussion post, comment or pull request I find inappropriate or that is not aligned with the Code of Conduct.

Similarly, I reserve the right to not accept any contribution that doesn't fit the goals or spirit of the project (or my own), without explaining why it has been refused.

## Decisions are final

You're welcome to make your case once, clearly. After that, please don't reopen closed issues, start meta-threads about the decision, or argue about the wording of this document. This is a list of expectations, not a contract to be lawyered. If something isn't covered, the maintainer's judgment applies.

This applies to Code of Conduct enforcement too. Reporting a violation is always welcome, privately, at the address given in the [Code of Conduct](CODE_OF_CONDUCT.md#enforcement), but the outcome is final.

## What happens elsewhere stays elsewhere

Contributions are judged on what they are, not on who sent them. What anyone says or does outside this project (on social media, at their job, in other repos, in politics) is not a topic here and will not be considered, either for or against them. Please don't bring it in: no call-outs, no "are you aware this person…" threads, no requests to ban someone over things that didn't happen here.

The [Code of Conduct](CODE_OF_CONDUCT.md#scope) applies within project spaces only, and defers to this document where the two differ.

## AI-generated issues and code

This project uses LLMs to produce code and artifacts, and it's fine if you do the same when contributing. LLM use in this project is settled: threads about whether it should be used (utility, harm, societal implications etc.) will be closed.

If you require LLM-untainted code for your needs, feel free to use zip_kit prior to and including commit 2f123ae41cffe7255f1ff0824af44420d5dbfaa7 - but I am not going to maintain an "LLM-free" branch of zip_kit just for your needs.
 
Please disclose LLM use in every issue and PR: say which model or tool you used and what for (e.g. "Claude wrote the fix, I wrote the test"). This is for transparency, not for judgment. Disclosed LLM use is treated the same as no LLM use.

However, the following is on you:

* Make your LLM output _terse._ Nobody likes reading slop, even my agents. Make it get to the point.
* Make sure what you submit actually ran. Don't file issues about behavior or APIs your LLM imagined.
* zip_kit has no runtime dependencies. Do not add any (or have your LLM do it) unless absolutely necessary
* If you file a PR, make at least one pass with "Make this at least 50% less code"
* Code generated by your LLM will be considered as written by you, with the same requirements

## License

By submitting a patch, you agree to allow the project owner to license your work under the same license as that used by the project, which you can see [here](LICENSE.txt).
