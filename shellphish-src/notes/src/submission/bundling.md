# Bundle Management

> From whitepaper [Section 9](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/notes/src/whitepaper/Artiphishell-3.md#9-submission):
>
> The Bundle Score (*BDL*) represents the ability of the CRS to associate PoVs, patches, and SARIF reports.
>
> BDL = sum of value_bundle, for all bundle in ScoringBundles
>
> where *ScoringBundles* are bundles that contain two or more PoVs, patches, or SARIF reports.
>
> The value of the bundle is computed as:
>
> value_bundle = 0.5 * (value_PoV + value_patch) + b, if both the PoV and patch are supplied; otherwise value_bundle = b
>
> where b takes the following values:
>
> - **0**: if no SARIF ID is included in the bundle, or the bundle contains incorrect pairings;
> - **1**: if the bundle has the correct pairing for the SARIF ID and the PoV but there is no patch included;
> - **2**: if the bundle has the correct pairing for the SARIF ID and the patch but has no PoV;
> - **3**: if the bundle contains correct pairings for SARIF ID, PoV, and patch.
>
> The definition of a correct pairing is as follows:
>
> - For a PoV and patch pairing the patch must remediate the PoV;
> - For a PoV and SARIF ID pairing, the PoV must crash the vulnerability defined in the SARIF report;
> - For a patch and SARIF ID pairing, the patch must fix the vulnerability described in the SARIF report;
> - For a PoV, patch, and SARIF ID pairing all of the above conditions must hold.
>
> At the end of the challenge round, there can be only one bundle submitted per SARIF ID or challenge vulnerability.
>
> Most importantly, if a bundle has an incorrect pairing, its value is detracted from the overall score, highlighting the fact that bundles represent high-risk/high-reward components of the score.
