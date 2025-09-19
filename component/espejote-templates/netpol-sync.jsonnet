local esp = import 'espejote.libsonnet';
local config = import 'lib/espejote-networkpolicy-sync/config.json';

// Common annotations and labels
local commonAnnotations = {
  'syn.tools/source': 'https://github.com/projectsyn/component-networkpolicy.git',
};
local commonItemLabels = {
  'app.kubernetes.io/managed-by': 'espejote',
  'app.kubernetes.io/part-of': 'syn',
  'app.kubernetes.io/component': 'networkpolicy',
};

// Extract the active policy sets from the given namespace object,
// based on the annotations applied by this ManagedResource.
local activePolicySets(namespace) =
  std.map(
    function(set) std.trim(set),
    std.split(
      std.get(std.get(namespace.metadata, 'annotations', { labels: {} }), config.annotations.activePolicySets, ''),
      ','
    )
  );

// Extract the desired policy sets from the given namespace object,
// based on the labels and desired default behaviour (isolation by default).
local desiredPolicySets(namespace) =
  local ignoreNamespace =
    std.member(config.ignoredNamespaces, namespace.metadata.name);
  local isNotIsolated =
    std.objectHas(std.get(namespace.metadata, 'labels', {}), config.labels.purgeDefaults) ||
    std.objectHas(std.get(namespace.metadata, 'labels', {}), config.labels.noDefaults);
  local isFullyIsolated =
    std.objectHas(std.get(namespace.metadata, 'labels', {}), config.labels.purgeNonBase) ||
    std.objectHas(std.get(namespace.metadata, 'labels', {}), config.labels.baseDefaults);

  local filterPolicySets = function(it)
    !std.member([ config.setNamespaceIsolationBasic, config.setNamespaceIsolationFull ], it);
  local splitPolicySetsLabel =
    std.map(
      function(set) std.trim(set),
      std.split(
        std.get(std.get(namespace.metadata, 'labels', { labels: {} }), config.labels.policySets, ''),
        ','
      )
    );

  // Return empty array if the namespace is ignored.
  // TODO: we should probably prune the active policy sets in namespaces that are ignored...
  // Maybe even annotate ignored namespaces with 'none'.
  if ignoreNamespace then [] else std.uniq(std.sort(std.prune(
    // Add policy sets based on the label params.labels.policySets.
    // Also filter out the default policy sets, as they should not be added by the policy sets label
    // and non-existing policy sets.
    std.filter(
      filterPolicySets,
      splitPolicySetsLabel
    )
    // Add default policy set 'namespace-isolation-full' if the namespace
    // has the label params.labels.baseDefaults set.
    + if isFullyIsolated then [ config.setNamespaceIsolationFull ]
    // Add no default policy set if the namespace
    // has the label params.labels.purgeDefaults or params.labels.noDefaults set.
    else if isNotIsolated then []
    // Add default policy set 'namespace-isolation' if the namespace
    // does not have the label params.labels.purgeDefaults or params.labels.noDefaults set.
    else [ config.setNamespaceIsolationBasic ]
  )));

// Extract the policy sets that should be deleted in that namespace,
// by subtracting the desired policy sets from the active policy sets.
local removedPolicySets(namespace) =
  std.filter(
    function(set) !std.member(desiredPolicySets(namespace), set),
    activePolicySets(namespace)
  );

// Generate policy sets.
local generatePolicyMetadata(policyName, namespace) =
  local isCiliumPolicy = std.startsWith(policyName, 'cilium/');
  {
    apiVersion: 'networking.k8s.io/v1',
    kind: 'NetworkPolicy',
    metadata: {
      annotations: commonAnnotations,
      labels: commonItemLabels,
      name: policyName,
      namespace: namespace.metadata.name,
    },
  }
  + if config.hasCilium && isCiliumPolicy then {
    apiVersion: 'cilium.io/v2',
    kind: 'CiliumNetworkPolicy',
    metadata+: {
      name: std.strReplace(policyName, 'cilium/', ''),
    },
  } else {};
local generatePolicySet(set, namespace) = std.filter(
  function(it) it != null,
  [
    generatePolicyMetadata(policyName, namespace) {
      spec: config.policies[policyName],
    }
    for policyName in config.policySets[set]
    if std.objectHas(config.policies, policyName)
  ]
);
local purgePolicySet(set, namespace) = std.filter(
  function(it) it != null,
  [
    esp.markForDelete(generatePolicyMetadata(policyName, namespace))
    for policyName in config.policySets[set]
    if std.objectHas(config.policies, policyName)
  ]
);
local generateNamespaceAnnotation(namespace) = [ {
  apiVersion: 'v1',
  kind: 'Namespace',
  metadata: {
    annotations: {
      [config.annotations.activePolicySets]: std.join(',', desiredPolicySets(namespace)),
    },
    name: namespace.metadata.name,
  },
} ];

// Reconcile the given namespace.
local reconcileNamespace(namespace) =
  // Generate array of NetworkPolicies for the given policy set.
  std.flattenArrays([
    generatePolicySet(set, namespace)
    for set in desiredPolicySets(namespace)
    if std.objectHas(config.policySets, set)
  ])
  // Generate array of NetworkPolicies to be deleted for the given policy set.
  + std.flattenArrays([
    purgePolicySet(set, namespace)
    for set in removedPolicySets(namespace)
    if std.objectHas(config.policySets, set)
  ])
  // Generate annotation for the given namespace containing the new active policy sets.
  + generateNamespaceAnnotation(namespace);

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
  local namespaces = esp.context().namespaces;
  std.flattenArrays([
    reconcileNamespace(ns)
    for ns in namespaces
    if !inDelete(ns)
  ])
)
