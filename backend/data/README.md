# RC Offline Vocabulary Dataset

`rc_vocab_seed.json` is the deterministic fallback used only when the seed CLI
cannot call the configured OpenAI-compatible provider and `--offline-fallback`
is explicitly enabled.

- Candidate words and Traditional Chinese translations are derived from
  [ECDICT](https://github.com/skywind3000/ECDICT), licensed under MIT.
- Example sentences are selected from Princeton WordNet. See
  `WORDNET_LICENSE` for its license terms.
- Candidates are limited to English dictionary words tagged for senior-school
  or Oxford study and ranked by BNC/COCA frequency data in ECDICT.
- RC levels 3-5 are deterministic frequency bands for offline bootstrapping;
  they are not represented as official CEEC level assignments.

The generated file contains no user data and no API credentials.
