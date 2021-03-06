import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:git_touch/models/bitbucket.dart';
import 'package:git_touch/models/gitea.dart';
import 'package:git_touch/utils/request_serilizer.dart';
import 'package:github/github.dart';
import 'package:gql_http_link/gql_http_link.dart';
import 'package:artemis/artemis.dart';
import 'package:fimber/fimber.dart';
import 'package:http/http.dart' as http;
import 'package:uni_links/uni_links.dart';
import 'package:nanoid/nanoid.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/utils.dart';
import 'account.dart';
import 'gitlab.dart';

const clientId = 'df930d7d2e219f26142a';

class PlatformType {
  static const github = 'github';
  static const gitlab = 'gitlab';
  static const bitbucket = 'bitbucket';
  static const gitea = 'gitea';
}

class DataWithPage<T> {
  T data;
  int cursor;
  bool hasMore;
  int total;
  DataWithPage({
    @required this.data,
    @required this.cursor,
    @required this.hasMore,
    this.total,
  });
}

class BbPagePayload<T> {
  T data;
  String cursor;
  bool hasMore;
  int total;
  BbPagePayload({
    @required this.data,
    @required this.cursor,
    @required this.hasMore,
    this.total,
  });
}

class AuthModel with ChangeNotifier {
  static const _apiPrefix = 'https://api.github.com';

  List<Account> _accounts;
  int activeAccountIndex;
  StreamSubscription<Uri> _sub;
  bool loading = false;

  List<Account> get accounts => _accounts;
  Account get activeAccount {
    if (activeAccountIndex == null || _accounts == null) return null;
    return _accounts[activeAccountIndex];
  }

  String get token => activeAccount.token;

  _addAccount(Account account) async {
    _accounts = [...accounts, account];
    // Save
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.accounts, json.encode(_accounts));
  }

  removeAccount(int index) async {
    if (activeAccountIndex == index) {
      activeAccountIndex = null;
    }
    _accounts.removeAt(index);
    // Save
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.accounts, json.encode(_accounts));
    notifyListeners();
  }

  // https://developer.github.com/apps/building-oauth-apps/authorizing-oauth-apps/#web-application-flow
  Future<void> _onSchemeDetected(Uri uri) async {
    await closeWebView();

    loading = true;
    notifyListeners();

    // Get token by code
    final res = await http.post(
      'https://git-touch-oauth.now.sh/api/token',
      headers: {
        HttpHeaders.acceptHeader: 'application/json',
        HttpHeaders.contentTypeHeader: 'application/json',
      },
      body: json.encode({
        'client_id': clientId,
        'code': uri.queryParameters['code'],
        'state': _oauthState,
      }),
    );
    final token = json.decode(res.body)['access_token'] as String;
    await loginWithToken(token);
  }

  Future<void> loginWithToken(String token) async {
    try {
      final queryData = await query('''
{
  viewer {
    login
    avatarUrl
  }
}
''', token);

      await _addAccount(Account(
        platform: PlatformType.github,
        domain: 'https://github.com',
        token: token,
        login: queryData['viewer']['login'] as String,
        avatarUrl: queryData['viewer']['avatarUrl'] as String,
      ));
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> loginToGitlab(String domain, String token) async {
    domain = domain.trim();
    token = token.trim();
    loading = true;
    notifyListeners();
    try {
      final res = await http
          .get('$domain/api/v4/user', headers: {'Private-Token': token});
      final info = json.decode(res.body);
      if (info['message'] != null) {
        throw info['message'];
      }
      final user = GitlabUser.fromJson(info);

      await _addAccount(Account(
        platform: PlatformType.gitlab,
        domain: domain,
        token: token,
        login: user.username,
        avatarUrl: user.avatarUrl,
        gitlabId: user.id,
      ));
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<String> fetchWithGitlabToken(String p) async {
    final res = await http.get(p, headers: {'Private-Token': token});
    return res.body;
  }

  Future fetchGitlab(String p) async {
    final res = await http.get('${activeAccount.domain}/api/v4$p',
        headers: {'Private-Token': token});
    final info = json.decode(utf8.decode(res.bodyBytes));
    if (info is Map && info['message'] != null) throw info['message'];
    return info;
  }

  Future<DataWithPage> fetchGitlabWithPage(String p) async {
    final res = await http.get('${activeAccount.domain}/api/v4$p',
        headers: {'Private-Token': token});
    final next = int.tryParse(
        res.headers['X-Next-Pages'] ?? res.headers['x-next-page'] ?? '');
    final info = json.decode(utf8.decode(res.bodyBytes));
    if (info is Map && info['message'] != null) throw info['message'];
    return DataWithPage(
      data: info,
      cursor: next,
      hasMore: next != null,
      total:
          int.tryParse(res.headers['X-Total'] ?? res.headers['x-total'] ?? ''),
    );
  }

  Future loginToGitea(String domain, String token) async {
    domain = domain.trim();
    token = token.trim();
    try {
      loading = true;
      notifyListeners();
      final res = await http.get('$domain/api/v1/user',
          headers: {'Authorization': 'token $token'});
      final info = json.decode(res.body);
      if (info['message'] != null) {
        throw info['message'];
      }
      final user = GiteaUser.fromJson(info);

      await _addAccount(Account(
        platform: PlatformType.gitea,
        domain: domain,
        token: token,
        login: user.login,
        avatarUrl: user.avatarUrl,
      ));
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future fetchGitea(String p) async {
    final res = await http.get('${activeAccount.domain}/api/v1$p',
        headers: {'Authorization': 'token $token'});
    final info = json.decode(utf8.decode(res.bodyBytes));
    return info;
  }

  Future<DataWithPage> fetchGiteaWithPage(String p) async {
    final res = await http.get('${activeAccount.domain}/api/v1$p',
        headers: {'Authorization': 'token $token'});
    final info = json.decode(utf8.decode(res.bodyBytes));
    return DataWithPage(
      data: info,
      cursor: int.tryParse(res.headers["x-page"] ?? ''),
      hasMore: res.headers['x-hasmore'] == 'true',
      total: int.tryParse(res.headers['x-total'] ?? ''),
    );
  }

  Future loginToBb(String domain, String username, String appPassword) async {
    domain = domain.trim();
    username = username.trim();
    appPassword = appPassword.trim();
    try {
      loading = true;
      notifyListeners();
      final uri = Uri.parse('$domain/api/2.0/user')
          .replace(userInfo: '$username:$appPassword');
      final res = await http.get(uri);
      if (res.statusCode >= 400) {
        throw 'status ${res.statusCode}';
      }
      final info = json.decode(res.body);
      final user = BbUser.fromJson(info);
      await _addAccount(Account(
        platform: PlatformType.bitbucket,
        domain: domain,
        token: user.username,
        login: username,
        avatarUrl: user.avatarUrl,
        appPassword: appPassword,
      ));
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<http.Response> fetchBb(String p) async {
    if (p.startsWith('/') && !p.startsWith('/api')) p = '/api/2.0$p';
    final input = Uri.parse(p);
    final uri = Uri.parse(activeAccount.domain).replace(
      userInfo: '${activeAccount.login}:${activeAccount.appPassword}',
      path: input.path,
      query: input.query,
    );
    return http.get(uri);
  }

  Future fetchBbJson(String p) async {
    final res = await fetchBb(p);
    return json.decode(utf8.decode(res.bodyBytes));
  }

  Future<BbPagePayload<List>> fetchBbWithPage(String p) async {
    final data = await fetchBbJson(p);
    final v = BbPagination.fromJson(data);
    return BbPagePayload(
      cursor: v.next,
      total: v.size,
      data: v.values,
      hasMore: v.next != null,
    );
  }

  Future<void> init() async {
    // Listen scheme
    _sub = getUriLinksStream().listen(_onSchemeDetected, onError: (err) {
      Fimber.e('getUriLinksStream failed', ex: err);
    });

    var prefs = await SharedPreferences.getInstance();

    // Read accounts
    try {
      String str = prefs.getString(StorageKeys.accounts);
      // Fimber.d('read accounts: $str');
      _accounts = (json.decode(str ?? '[]') as List)
          .map((item) => Account.fromJson(item))
          .toList();
    } catch (err) {
      Fimber.e('prefs getAccount failed', ex: err);
      _accounts = [];
    }

    notifyListeners();
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  var rootKey = UniqueKey();
  void setActiveAccountAndReload(int index) {
    // https://stackoverflow.com/a/50116077
    rootKey = UniqueKey();
    activeAccountIndex = index;
    _ghClient = null;
    _gqlClient = null;
    notifyListeners();
  }

  Map<String, String> get _headers =>
      {HttpHeaders.authorizationHeader: 'token $token'};

  // http timeout
  var _timeoutDuration = Duration(seconds: 10);
  // var _timeoutDuration = Duration(seconds: 1);

  GitHub _ghClient;
  GitHub get ghClient {
    if (token == null) return null;
    if (_ghClient == null) {
      _ghClient = GitHub(auth: Authentication.withToken(token));
    }
    return _ghClient;
  }

  ArtemisClient _gqlClient;
  ArtemisClient get gqlClient {
    if (token == null) return null;

    if (_gqlClient == null) {
      _gqlClient = ArtemisClient.fromLink(
        HttpLink(
          _apiPrefix + '/graphql',
          defaultHeaders: {HttpHeaders.authorizationHeader: 'token $token'},
          serializer: GithubRequestSerializer(),
        ),
      );
    }

    return _gqlClient;
  }

  Future<dynamic> query(String query, [String _token]) async {
    if (_token == null) {
      _token = token;
    }
    if (_token == null) {
      throw 'token is null';
    }

    final res = await http
        .post(_apiPrefix + '/graphql',
            headers: {
              HttpHeaders.authorizationHeader: 'token $_token',
              HttpHeaders.contentTypeHeader: 'application/json'
            },
            body: json.encode({'query': query}))
        .timeout(_timeoutDuration);

    // Fimber.d(res.body);
    final data = json.decode(res.body);

    if (data['errors'] != null) {
      throw data['errors'][0]['message'];
    }

    return data['data'];
  }

  String _oauthState;
  void redirectToGithubOauth() {
    _oauthState = nanoid();
    var scope = Uri.encodeComponent('user,repo,read:org,notifications');
    launchUrl(
      'https://github.com/login/oauth/authorize?client_id=$clientId&redirect_uri=gittouch://login&scope=$scope&state=$_oauthState',
    );
  }
}
