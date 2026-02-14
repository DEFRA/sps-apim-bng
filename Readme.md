# SPS-APIM-BNG

> ⚠️ **This repository contains under-development code and is used for APIM self-service development purposes.**

## Overview
This repository stores the **source-of-truth for APIM configuration** for the Address Lookup APIs (operations, versions, policies, products, and named values) and the automation required to deploy to **Dev → Test → Prod** through Azure DevOps.

It follows the Shared Platform DevOps patterns used by the team:
- **GitHub as source control** with **Azure DevOps Pipelines** as the deployment engine.
- **Branching:** feature → `develop` → `master` (release) with automated deployments.
- **Versioning:** use **tags**/releases (e.g. `v1.0.0`, `v10`).
---

## Repository Structure
```
SPS-APIM-GATEWAY-ADDRESS-LOOKUP-V10/
├─ .github/
│  └─ workflows/                # GitHub Actions workflows (optional CI checks)
├─ external/
│  └─ base/
│     ├─ apis/                  # External-facing API definitions
│     ├─ named values/          # Named values for external APIs
│     ├─ products/              # External products configuration
│     └─ version sets/          # External API version sets
├─ internal/
│  └─ base/
│     ├─ apis/                  # Internal-facing API definitions
│     ├─ named values/          # Named values for internal APIs
│     ├─ products/              # Internal products configuration
│     └─ version sets/          # Internal API version sets
├─ LICENCE                      # Open Government Licence v3
└─ Readme.md                    # Project documentation
```
## Security & Repository Policy

This repository follows GOV.UK guidance on **open vs closed code**:

- **Committed to Git**:
  - API metadata (`apiInformation.json`)
  - OpenAPI specification (`specification.yaml`)
  - APIM policy templates (`policy.xml`) with placeholders
  - Named value metadata (`namedValueInformation.json`) without actual secret values
  - Version set metadata (`versionSetInformation.json`)

- **Not committed to Git**:
  - Any real **secret values**, API keys, certificates, or connection strings
  - Environment-specific overrides (e.g., `parameters.local.json`)
  - Certificates (`.pfx`, `.pem`, `.key`) or `.env` files

**Sensitive values are injected at deploy time via Azure Key Vault or Azure DevOps variable groups.**  
Policies and configuration reference these values using placeholders like `{{ variableName }}`.

## Quick Start
1. Clone and create a feature branch:
   ```bash
   git clone <repo-url>
   cd sps-apim-gateway-address-lookup
   git checkout -b feature/<ticket-id>-short-description
   ```
2. Edit OpenAPI under `apis/address-lookup/api-definition/openapi.yaml`.
3. Update policies in `policies/`.
4. Commit and push:
   ```bash
   git add .
   git commit -m "feat(address-lookup): add /v1/addresses/search"
   git push origin feature/<ticket-id>-short-description
   ```
5. Open PR → `develop`.

## CI/CD
- **On merge to `develop`:** Deploys to Dev and Test.
- **On merge to `master`:** Deploys to all environments with approval.

### CI/CD Sequence Diagrams
#### CI/CD Flow for `develop` Branch
```mermaid
sequenceDiagram
    autonumber
    actor Dev as Developer
    participant GH as GitHub Repo
    participant GHA as GitHub Actions (CI checks)
    participant ADO as Azure DevOps Pipeline (CD)
    participant KV as Azure Key Vault
    participant APIMDev as APIM - Dev
    participant APIMTest as APIM - Test

    Note over Dev,GH: Feature branch PR -> merge to <develop>
    Dev->>GH: Merge PR to <develop>
    activate GH
    GH-->>ADO: Service hook trigger (DEFRA connection / PAT)
    deactivate GH

    activate ADO
    ADO->>ADO: Checkout repository
    ADO->>ADO: Validate OpenAPI & policy XML (scripts/Validate-OpenApi.ps1)
    ADO->>ADO: Detect changes (scripts/Detect-ChangedProjects.ps1)
    alt Any API folders changed?
        ADO->>ADO: Package only changed API assets
        ADO->>KV: Resolve secrets via Named Values (Key Vault refs)
        ADO->>APIMDev: Deploy changed APIs (api-ops-publisher.yaml)
        APIMDev-->>ADO: Deployment result (Dev)
        ADO->>APIMTest: Deploy changed APIs after Dev validation
        APIMTest-->>ADO: Deployment result (Test)
    else No changes detected
        ADO-->>GH: Skip deployment (no changed API content)
    end
    ADO-->>GH: Report status (checks/summary)
    deactivate ADO

    Note over GH,ADO: Build status visible in GitHub (via ADO pipeline status)
```

#### CI/CD Flow for `master` Branch
```mermaid
sequenceDiagram
    autonumber
    actor Dev as Developer
    participant GH as GitHub Repo
    participant ADO as Azure DevOps Pipeline (Release)
    participant Approver as Release Approver
    participant KV as Azure Key Vault
    participant APIMDev as APIM - Dev
    participant APIMTest as APIM - Test
    participant APIMProd as APIM - Prod

    Note over Dev,GH: Release PR -> merge to <master> (tag as needed, e.g. v1.0.0)
    Dev->>GH: Merge PR to <master>
    activate GH
    GH-->>ADO: Service hook trigger (DEFRA connection / PAT)
    deactivate GH

    activate ADO
    ADO->>ADO: Checkout repository
    ADO->>ADO: Validate OpenAPI & policy XML
    ADO->>ADO: Detect changes (scripts/Detect-ChangedProjects.ps1)
    alt Any API folders changed?
        ADO->>ADO: Package only changed API assets
        ADO->>KV: Resolve secrets via Named Values (Key Vault refs)
        ADO->>APIMDev: Deploy changed APIs (Dev)
        APIMDev-->>ADO: Deployment result (Dev)
        ADO->>APIMTest: Deploy changed APIs (Test)
        APIMTest-->>ADO: Deployment result (Test)

        Note over ADO,Approver: Pre-Prod/Prod approval gate
        ADO-->>Approver: Request approval (manual check)
        Approver-->>ADO: Approve or Reject
        alt Approved
            ADO->>APIMProd: Deploy changed APIs (Prod)
            APIMProd-->>ADO: Deployment result (Prod)
        else Rejected
            ADO-->>GH: Mark release pipeline as failed / blocked
        end
    else No changes detected
        ADO-->>GH: Skip deployment (no changed API content)
    end
    ADO-->>GH: Report status (checks/summary)
    deactivate ADO
```

#### Git Subtree Sync Flow
```mermaid
sequenceDiagram
    autonumber
    actor TeamDev as Team Developer
    participant TeamRepo as Team API Repo
    participant Central as Central Gateway Repo
    participant GH as GitHub (Central)
    participant ADO as Azure DevOps Pipeline (Central)

    TeamDev->>TeamRepo: Commit API/policy changes
    TeamDev->>TeamRepo: git subtree push --prefix apis/address-lookup <central> main
    TeamRepo-->>Central: Subtree changes updated

    Central->>GH: Push to central repo (develop/master)
    GH-->>ADO: Trigger pipeline (service connection DEFRA)
    ADO->>...: Deploy per environment as per branch rules
```

## Local Validation
```powershell
./scripts/Validate-APIMStructure.ps1" -RootPath . -ParentFolders "external,internal" -Environments "base"
```

## Contacts
- **Maintainer:** Prathap Mathiyalagan  
- **Manager:** David Wickett
- **Development team:** GIO Shared platform - Integration team (ICC)

## License
This repository uses the [Open Governmentnalarchives.gov.uk/doc/open-government-licence/version/3](https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/).

> Contains public sector information licensed under the Open Government Licence v3.
