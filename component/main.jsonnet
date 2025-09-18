local com = import 'lib/commodore.libjsonnet';
local esp = import 'lib/espejote.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local resources = import 'espejote-templates/netpol-resources.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.networkpolicy;

local espNamespace = inv.parameters.espejote.namespace;
local mrName = 'espejote-networkpolicy-sync';
local rbacName = 'espejote-managedresource-networkpolicy-sync';

// RBAC for Espejote
local espejoteRBAC = [
  {
    apiVersion: 'v1',
    kind: 'ServiceAccount',
    metadata: {
      labels: {
        'app.kubernetes.io/component': 'networkpolicy',
        'app.kubernetes.io/name': mrName,
      },
      name: mrName,
      namespace: espNamespace,
    },
  },
  {
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'ClusterRole',
    metadata: {
      labels: {
        'app.kubernetes.io/component': 'networkpolicy',
        'app.kubernetes.io/name': rbacName,
      },
      name: rbacName,
    },
    rules: [
      {
        apiGroups: [ '' ],
        resources: [ 'namespaces' ],
        verbs: [ 'get', 'list', 'watch' ],
      },
      {
        apiGroups: [ 'espejote.io' ],
        resources: [ 'jsonnetlibraries' ],
        resourceNames: [ mrName ],
        verbs: [ 'get', 'list', 'watch' ],
      },
      {
        apiGroups: [ 'networking.k8s.io' ],
        resources: [ 'networkpolicies' ],
        verbs: [ 'get', 'list', 'watch', 'patch', 'create', 'delete' ],
      },
      {
        apiGroups: [ 'cilium.io' ],
        resources: [ 'ciliumnetworkpolicies' ],
        verbs: [ 'get', 'list', 'watch', 'patch', 'create', 'delete' ],
      },
    ],
  },
  {
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'ClusterRoleBinding',
    metadata: {
      labels: {
        'app.kubernetes.io/component': 'networkpolicy',
        'app.kubernetes.io/name': rbacName,
      },
      name: rbacName,
    },
    roleRef: {
      apiGroup: 'rbac.authorization.k8s.io',
      kind: 'ClusterRole',
      name: rbacName,
    },
    subjects: [
      {
        kind: 'ServiceAccount',
        name: mrName,
        namespace: espNamespace,
      },
    ],
  },
];

// Espejote resources
local jsonnetLibrary = esp.jsonnetLibrary(mrName, espNamespace) {
  spec: {
    data: {
      'config.json': std.manifestJson({
        labels: params.labels,
        allowNamespaceLabels: params.allowNamespaceLabels,
        ignoredNamespaces: com.renderArray(params.ignoredNamespaces),
        networkPlugin: std.asciiLower(params.networkPlugin),
        ciliumClusterID: params.ciliumClusterID,
        allowFromNodeLabels: params.allowFromNodeLabels,
      }),
      'resources.libsonnet': importstr 'espejote-templates/netpol-resources.libsonnet',
    },
  },
};

local managedResource = esp.managedResource(mrName, espNamespace) {
  metadata+: {
    annotations: {
      'syn.tools/description': |||
        This managed resource purges existing network policies if they are
        deployed in a namespace that is in the list of ignored namespaces.
      |||,
    },
  },
  spec: {
    context: [
      {
        name: 'namespace',
        resource: {
          apiVersion: 'v1',
          kind: 'Namespace',
        },
      },
    ],
    triggers: [
      {
        name: 'jslib',
        watchResource: {
          apiVersion: jsonnetLibrary.apiVersion,
          kind: 'JsonnetLibrary',
          name: jsonnetLibrary.metadata.name,
          namespace: jsonnetLibrary.metadata.namespace,
        },
      },
      {
        name: 'namespace',
        watchContextResource: {
          name: 'namespace',
        },
      },
      {
        name: 'netpol',
        watchResource: {
          apiVersion: resources.allowFromOtherNamespaces.apiVersion,
          kind: resources.allowFromOtherNamespaces.kind,
          matchNames: [
            resources.allowFromOtherNamespaces.metadata.name,
            resources.allowFromSameNamespace.metadata.name,
          ],
          namespace: '',
        },
      },
      {
        name: 'ciliumpol',
        watchResource: {
          apiVersion: resources.allowFromClusterNodes.apiVersion,
          kind: resources.allowFromClusterNodes.kind,
          matchNames: [
            resources.allowFromClusterNodes.metadata.name,
          ],
          namespace: '',
        },
      },
    ],
    serviceAccountRef: {
      name: espejoteRBAC[0].metadata.name,
    },
    applyOptions: {
      force: true,
    },
    template: importstr 'espejote-templates/netpol-sync.jsonnet',
  },
};

// Check if espejote is installed
local has_espejote = std.member(inv.applications, 'espejote');

// Define outputs below
if has_espejote then
  {
    '01_rbac': espejoteRBAC,
    '02_library': jsonnetLibrary,
    '03_managedresource': managedResource,
  }
else
  std.trace(
    'espejote must be installed',
    {}
  )
