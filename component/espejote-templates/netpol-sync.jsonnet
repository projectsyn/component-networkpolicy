local esp = import 'espejote.libsonnet';
local config = import 'lib/espejote-networkpolicy-sync/config.json';
local resources = import 'lib/espejote-networkpolicy-sync/resources.libsonnet';

local isPurgeNonBase(namespace) =
  std.objectHas(std.get(namespace.metadata, 'labels', {}), config.labels.purgeNonBase);

local isPurgeDefaults(namespace) =
  std.member(config.ignoredNamespaces, namespace.metadata.name) ||
  std.objectHas(std.get(namespace.metadata, 'labels', {}), config.labels.purgeDefaults) ||
  std.objectHas(std.get(namespace.metadata, 'labels', {}), config.labels.noDefaults);

local isApplyBase(namespace) =
  std.objectHas(std.get(namespace.metadata, 'labels', {}), config.labels.baseDefaults);

local purgeNonBasePolicies(namespace) = [
  esp.markForDelete({
    apiVersion: resources.allowFromSameNamespace.apiVersion,
    kind: resources.allowFromSameNamespace.kind,
    metadata: {
      name: resources.allowFromSameNamespace.metadata.name,
      namespace: namespace.metadata.name,
    },
  }),
];

local purgeDefaultPolicies(namespace) =
  purgeNonBasePolicies(namespace) + [
    esp.markForDelete({
      apiVersion: resources.allowFromOtherNamespaces.apiVersion,
      kind: resources.allowFromOtherNamespaces.kind,
      metadata: {
        name: resources.allowFromOtherNamespaces.metadata.name,
        namespace: namespace.metadata.name,
      },
    }),
    esp.markForDelete({
      apiVersion: resources.allowFromClusterNodes.apiVersion,
      kind: resources.allowFromClusterNodes.kind,
      metadata: {
        name: resources.allowFromClusterNodes.metadata.name,
        namespace: namespace.metadata.name,
      },
    }),
  ];

local applyBasePolicies(namespace) = [
  resources.allowFromOtherWithSpec {
    metadata+: {
      namespace: namespace.metadata.name,
    },
  },
] + if config.networkPlugin == 'cilium' then [
  resources.allowFromNodesWithSpec {
    metadata+: {
      namespace: namespace.metadata.name,
    },
  },
] else [];

local applyDefaultPolicies(namespace) =
  applyBasePolicies(namespace) + [
    resources.allowFromSameWithSpec {
      metadata+: {
        namespace: namespace.metadata.name,
      },
    },
  ];

local reconcileNamespace(namespace) =
  // Purge NetworkPolicies and CiliumNetworkPolicies if the namespace
  // has the purgeNonBase label.
  if isPurgeNonBase(namespace) then purgeNonBasePolicies(namespace)
  // Purge NetworkPolicies and CiliumNetworkPolicies if the namespace
  // is either in the ignoredNamespaces list or has the purgeDefaults label.
  else if isPurgeDefaults(namespace) then purgeDefaultPolicies(namespace)
  // Apply base NetworkPolicies and CiliumNetworkPolicies if the namespace
  // has the baseDefaults label.
  else if isApplyBase(namespace) then applyBasePolicies(namespace)
  // Apply default NetworkPolicies and CiliumNetworkPolicies if the namespace
  // nothing else applies.
  else applyDefaultPolicies(namespace);

// check if the object is getting deleted by checking if it has
// `metadata.deletionTimestamp`.
local inDelete(obj) = std.get(obj.metadata, 'deletionTimestamp', '') != '';

// Do the thing
if esp.triggerName() == 'namespace' then (
  // Handle single namespace update on namespace trigger
  local nsTrigger = esp.triggerData();
  // nsTrigger can be null if we're called when the namespace is getting
  // deleted. If it's not null, we still don't want to do anything when the
  // namespace is getting deleted.
  if nsTrigger != null && !inDelete(nsTrigger.resource) then
    reconcileNamespace(nsTrigger.resource)
) else (
  // Reconcile all namespaces for jsonnetlibrary update or managedresource
  // reconcile.
  local namespaces = esp.context().namespace;
  std.flattenArrays([
    reconcileNamespace(ns)
    for ns in namespaces
    if !inDelete(ns)
  ])
)
