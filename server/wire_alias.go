package main

import "ccmuxd/wire"

// The wire contract lives in package wire so the Linux agent can import it without
// pulling in the server. These aliases are what keep every other file here spelling the
// types the way it always has — and being aliases, not definitions, a value built here is
// the same type the agent decodes.

type (
	Time                  = wire.Time
	AccountKind           = wire.AccountKind
	AccountHealth         = wire.AccountHealth
	RemoteAccount         = wire.RemoteAccount
	TokenGrant            = wire.TokenGrant
	RemoteUsage           = wire.RemoteUsage
	LoginStartRequest     = wire.LoginStartRequest
	LoginStartResponse    = wire.LoginStartResponse
	LoginFinishRequest    = wire.LoginFinishRequest
	AdoptRequest          = wire.AdoptRequest
	AccountUpdate         = wire.AccountUpdate
	SubscriptionGroup     = wire.SubscriptionGroup
	GroupListResponse     = wire.GroupListResponse
	GroupRequest          = wire.GroupRequest
	AccountListResponse   = wire.AccountListResponse
	HealthResponse        = wire.HealthResponse
	MachineSession        = wire.MachineSession
	MachineReport         = wire.MachineReport
	MachineSnapshot       = wire.MachineSnapshot
	SessionsResponse      = wire.SessionsResponse
	ServerErrorResponse   = wire.ServerErrorResponse
	ServerErrorDetail     = wire.ServerErrorDetail
	HookFile              = wire.HookFile
	HookBundle            = wire.HookBundle
	HookPushRequest       = wire.HookPushRequest
	HookActivationRequest = wire.HookActivationRequest
	UsageBucket           = wire.UsageBucket
	UsageReport           = wire.UsageReport
	UsageIngestResponse   = wire.UsageIngestResponse
	UsageTotals           = wire.UsageTotals
	UsagePoint            = wire.UsagePoint
	UsageSeries           = wire.UsageSeries
	UsageAccountTotals    = wire.UsageAccountTotals
	UsageStatsResponse    = wire.UsageStatsResponse
	UsageWindow           = wire.UsageWindow
	WindowKind            = wire.WindowKind
)

const (
	apiPrefix             = wire.APIPrefix
	apiVersion            = wire.APIVersion
	KindSubscription      = wire.KindSubscription
	KindAPIKey            = wire.KindAPIKey
	HealthOK              = wire.HealthOK
	HealthNeedsRelogin    = wire.HealthNeedsRelogin
	HealthUnknown         = wire.HealthUnknown
	WindowSession         = wire.WindowSession
	WindowWeeklyAll       = wire.WindowWeeklyAll
	WindowWeeklyScoped    = wire.WindowWeeklyScoped
	WindowOther           = wire.WindowOther
	featureSessions       = wire.FeatureSessions
	featureHooks          = wire.FeatureHooks
	featureHookActivation = wire.FeatureHookActivation
	featureUsageSeries    = wire.FeatureUsageSeries
)

var serverFeatures = wire.ServerFeatures

// Still here rather than in wire: every construction site in this package uses it, and
// the wire package exports its own Ptr for the agent's.
func ptr[T any](v T) *T { return &v }
