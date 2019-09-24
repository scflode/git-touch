import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:git_touch/models/theme.dart';
import 'package:provider/provider.dart';
import '../widgets/loading.dart';
import '../widgets/error_reload.dart';

class RefreshScaffold<T> extends StatefulWidget {
  final Widget title;
  final Widget Function(T payload) bodyBuilder;
  final Future<T> Function() onRefresh;
  final Widget Function(T payload) trailingBuilder;

  RefreshScaffold({
    @required this.title,
    @required this.bodyBuilder,
    @required this.onRefresh,
    this.trailingBuilder,
  });

  @override
  _RefreshScaffoldState createState() => _RefreshScaffoldState();
}

class _RefreshScaffoldState<T> extends State<RefreshScaffold<T>> {
  bool _loading;
  T _payload;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Widget _buildBody() {
    if (_error.isNotEmpty) {
      return ErrorReload(text: _error, onTap: _refresh);
    } else if (_payload == null) {
      return Loading(more: false);
    } else {
      return widget.bodyBuilder(_payload);
    }
  }

  Future<void> _refresh() async {
    try {
      setState(() {
        _error = '';
        _loading = true;
      });
      _payload = await widget.onRefresh();
    } catch (err) {
      _error = err.toString();
      throw err;
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Widget _buildTrailing() {
    if (_payload == null || widget.trailingBuilder == null) return null;

    return widget.trailingBuilder(_payload);
  }

  List<Widget> _buildActions() {
    if (_payload == null || widget.trailingBuilder == null) return null;
    var w = widget.trailingBuilder(_payload);
    return [if (w != null) w];
  }

  @override
  Widget build(BuildContext context) {
    switch (Provider.of<ThemeModel>(context).theme) {
      case AppThemeType.cupertino:
        return CupertinoPageScaffold(
          navigationBar: CupertinoNavigationBar(
            middle: widget.title,
            trailing: _buildTrailing(),
          ),
          child: SafeArea(
            child: CustomScrollView(
              slivers: <Widget>[
                CupertinoSliverRefreshControl(onRefresh: _refresh),
                SliverToBoxAdapter(child: _buildBody())
              ],
            ),
          ),
        );
      default:
        return Scaffold(
          appBar: AppBar(
            title: widget.title,
            actions: _buildActions(),
          ),
          body: RefreshIndicator(
            onRefresh: _refresh,
            child: SingleChildScrollView(child: _buildBody()),
          ),
        );
    }
  }
}
