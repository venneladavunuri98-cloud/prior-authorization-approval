# Data model

## `prior_auth_requests`
One row per request: `request_id, status, requesting_physician_name, patient_id, encounter_id, procedure_code, diagnosis_codes, physician_npi, payer_id, payer_name, payer_member_id, clinical_extraction, urgency_level, auth_number, is_approved, tracking_id, submitted_at, denial_reason`

## `physician_approvals`
`approval_id, request_id, decision (empty until decided), decided_at, expires_at` (created by Workflow A, valid for 24 hours)

## RPC `decrypt_patient_phi(req_id)`
Returns `patient_name, patient_dob`. Identity data stays encrypted at rest and is decrypted only inside this function, called right before submission.

## Status lifecycle
| Status | Set when | Notification |
|---|---|---|
| `manual_review_needed` | Physician clicked Reject | none (staff queue) |
| `ineligible` | Availity says coverage isn't active | billing staff |
| `approved` | Payer approved; auth number stored | care team |
| `denied` | Payer denied; reason stored | physician gets an appeal draft |
| `pending` | Submitted, no final answer | none |
