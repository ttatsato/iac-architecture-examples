# Multi-User Secure Proxy with Static IP

## Context

The following business requirements must be satisfied at the same time.

- Comply with partner and external SaaS IP allowlist requirements by using a fixed egress IP
- Reflect user onboarding/offboarding quickly in access permissions
- Provide an explainable access path and control model for audits
- Minimize public exposure and reduce the attack surface
- Keep operational cost and overhead sustainable for a small team

## Decision

Adopt the following architecture on GCP.

- **Fixed IP (Exit)**: Assign a static IP to Compute Engine and register it in external allowlists
- **Identity-Centric Secure Access (Gate)**: Use IAP and require Google account authentication (Zero Trust-aligned, not a full ZTA implementation)
- **Client Route Control (Control)**: Enforce proxy routing for target URLs through endpoint policy (implementation aligned with organizational standards)
- **IaC**: Manage network, IAM, VM, and firewall as code with Terraform
- **Proxy Runtime**: Run Squid on Docker

## Decision Drivers

- Maintain a high success rate when connecting to IP-restricted services
- Strengthen authentication controls without rolling out a full VPN stack
- Improve change management and audit explainability
- Keep the design practical for day-to-day operation by a small team

## Alternatives Considered

### 1) Full VPN model

- **Pros**: Easier to establish a strong network boundary
- **Cons**: High implementation and operational overhead; overkill for small-scale usage
- **Why not chosen**: Cost and operational complexity are too high for current requirements

### 2) Public proxy + IP allowlist

- **Pros**: Relatively easy to build
- **Cons**: Increases public exposure, risk, and audit burden
- **Why not chosen**: Conflicts with the requirement to minimize attack surface

### 3) Chosen: Fixed IP + IAP + endpoint route control

- **Pros**: Good balance among security, operability, and cost
- **Cons**: Depends on GCP/IAP/IAM and endpoint policy operations
- **Why chosen**: Satisfies core business requirements with a minimal, practical baseline

### 4) Device-compliance enforcement including CEP (out of scope for this phase)

- **Pros**: Enables stronger zero-trust controls based on both account and device posture
- **Cons**: Requires significant investment in endpoint management, compliance policy design, and operational readiness
- **Why not chosen now**: Considered as a valid option, but this phase prioritizes a robust account-based baseline with MFA and firewall controls first

## Consequences

### Positive

- Egress IP is centralized, stabilizing allowlist operations
- Access can be controlled at the account level, enabling fast onboarding/offboarding
- Infrastructure changes are codified, improving reviewability, reproducibility, and auditability
- Public exposure is reduced
- Avoids over-engineered endpoint controls in phase one and enables faster rollout

### Negative / Trade-offs

- Increased dependency on GCP services (IAP/IAM/Compute)
- Stronger zero-trust posture with device compliance (such as CEP) must be implemented in a later phase
- Requires disciplined Terraform and IAM governance

## Implementation Notes

- VM: Compute Engine (COS), with `e2-micro` as the initial sizing assumption
- Proxy: Docker + Squid
- Access: IAP tunnel is the default access path
- Management: Centrally managed with Terraform

## Review Trigger

Re-evaluate this ADR when any of the following occurs.

- User count or traffic exceeds the assumptions for `e2-micro`
- External services change authentication models or connectivity requirements
- Audit or security requirements become stricter
