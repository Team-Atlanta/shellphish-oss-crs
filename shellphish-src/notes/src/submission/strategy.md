# Submission Strategy

> From whitepaper [Section 9](https://github.com/sslab-gatech/shellphish-afc-crs/blob/main/notes/src/whitepaper/Artiphishell-3.md#9-submission):
>
> The submission process is critical, as it must take into account the rules of the competition to maximize the CRS score.
>
> The PatcherG agent is responsible for keeping track of which POVs, patches, and SARIF analysis reports have been submitted as well as their "bundling." Bundling is the process of associating a crashing seed (i.e., a PoV) with a specific patch (and possibly a SARIF report). Bundles that correctly associate PoVs and patches receive a higher score. However, incorrect association of crashing seeds and patches can lead to the loss of points.
>
> The overall score for the competition is the sum of all the challenge rounds performed by the Cyber Reasoning System (CRS). Each round has a fixed duration *CT* (which is usually between 6 hours and 12 hours), and each event is marked with the time remaining in the duration of the challenge, *RT*.
>
> The score for a challenge round (CS) is determined by various factors:
>
> CS = AM * (VDS + PRS + SAS + BDL)
>
> where *AM* is the Accuracy Multiplier, *VDS* is the Vulnerability Discovery Score, *PRS* is the Program Repair Score, *SAS* is the SARIF Assessment Score, and *BDL* is the Bundle Score.
>
> **Accuracy Multiplier**: AM = 1 - (1 - r)^4, where r is the ratio of accurate submissions to all submissions.
>
> **Vulnerability Discovery Score (VDS)**: represents the CRS' ability to find vulnerabilities and produce inputs that trigger them (PoVs). value_PoV = 2 * (0.5 + RT/(2 * CT))
>
> **Program Repair Score (PRS)**: represents the ability of the CRS to generate effective patches. value_patch = 6 * (0.5 + RT/(2 * CT))
>
> **SARIF Assessment Score (SAS)**: measures the ability of the CRS to validate a SARIF report. value_assessment = 1 * (0.5 + RT/(2 * SRT))
>
> **Bundle Score (BDL)**: represents the ability of the CRS to associate PoVs, patches, and SARIF reports. Most importantly, if a bundle has an incorrect pairing, its value is detracted from the overall score, highlighting the fact that bundles represent high-risk/high-reward components of the score.
