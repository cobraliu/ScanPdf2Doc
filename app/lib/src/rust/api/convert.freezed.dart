// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'convert.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$Progress {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Progress);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'Progress()';
}


}

/// @nodoc
class $ProgressCopyWith<$Res>  {
$ProgressCopyWith(Progress _, $Res Function(Progress) __);
}


/// Adds pattern-matching-related methods to [Progress].
extension ProgressPatterns on Progress {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( Progress_Loading value)?  loading,TResult Function( Progress_Page value)?  page,TResult Function( Progress_Writing value)?  writing,TResult Function( Progress_Done value)?  done,required TResult orElse(),}){
final _that = this;
switch (_that) {
case Progress_Loading() when loading != null:
return loading(_that);case Progress_Page() when page != null:
return page(_that);case Progress_Writing() when writing != null:
return writing(_that);case Progress_Done() when done != null:
return done(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( Progress_Loading value)  loading,required TResult Function( Progress_Page value)  page,required TResult Function( Progress_Writing value)  writing,required TResult Function( Progress_Done value)  done,}){
final _that = this;
switch (_that) {
case Progress_Loading():
return loading(_that);case Progress_Page():
return page(_that);case Progress_Writing():
return writing(_that);case Progress_Done():
return done(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( Progress_Loading value)?  loading,TResult? Function( Progress_Page value)?  page,TResult? Function( Progress_Writing value)?  writing,TResult? Function( Progress_Done value)?  done,}){
final _that = this;
switch (_that) {
case Progress_Loading() when loading != null:
return loading(_that);case Progress_Page() when page != null:
return page(_that);case Progress_Writing() when writing != null:
return writing(_that);case Progress_Done() when done != null:
return done(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  loading,TResult Function( int index,  int total)?  page,TResult Function()?  writing,TResult Function( ConvertReport report)?  done,required TResult orElse(),}) {final _that = this;
switch (_that) {
case Progress_Loading() when loading != null:
return loading();case Progress_Page() when page != null:
return page(_that.index,_that.total);case Progress_Writing() when writing != null:
return writing();case Progress_Done() when done != null:
return done(_that.report);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  loading,required TResult Function( int index,  int total)  page,required TResult Function()  writing,required TResult Function( ConvertReport report)  done,}) {final _that = this;
switch (_that) {
case Progress_Loading():
return loading();case Progress_Page():
return page(_that.index,_that.total);case Progress_Writing():
return writing();case Progress_Done():
return done(_that.report);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  loading,TResult? Function( int index,  int total)?  page,TResult? Function()?  writing,TResult? Function( ConvertReport report)?  done,}) {final _that = this;
switch (_that) {
case Progress_Loading() when loading != null:
return loading();case Progress_Page() when page != null:
return page(_that.index,_that.total);case Progress_Writing() when writing != null:
return writing();case Progress_Done() when done != null:
return done(_that.report);case _:
  return null;

}
}

}

/// @nodoc


class Progress_Loading extends Progress {
  const Progress_Loading(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Progress_Loading);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'Progress.loading()';
}


}




/// @nodoc


class Progress_Page extends Progress {
  const Progress_Page({required this.index, required this.total}): super._();
  

 final  int index;
 final  int total;

/// Create a copy of Progress
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Progress_PageCopyWith<Progress_Page> get copyWith => _$Progress_PageCopyWithImpl<Progress_Page>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Progress_Page&&(identical(other.index, index) || other.index == index)&&(identical(other.total, total) || other.total == total));
}


@override
int get hashCode => Object.hash(runtimeType,index,total);

@override
String toString() {
  return 'Progress.page(index: $index, total: $total)';
}


}

/// @nodoc
abstract mixin class $Progress_PageCopyWith<$Res> implements $ProgressCopyWith<$Res> {
  factory $Progress_PageCopyWith(Progress_Page value, $Res Function(Progress_Page) _then) = _$Progress_PageCopyWithImpl;
@useResult
$Res call({
 int index, int total
});




}
/// @nodoc
class _$Progress_PageCopyWithImpl<$Res>
    implements $Progress_PageCopyWith<$Res> {
  _$Progress_PageCopyWithImpl(this._self, this._then);

  final Progress_Page _self;
  final $Res Function(Progress_Page) _then;

/// Create a copy of Progress
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? index = null,Object? total = null,}) {
  return _then(Progress_Page(
index: null == index ? _self.index : index // ignore: cast_nullable_to_non_nullable
as int,total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class Progress_Writing extends Progress {
  const Progress_Writing(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Progress_Writing);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'Progress.writing()';
}


}




/// @nodoc


class Progress_Done extends Progress {
  const Progress_Done({required this.report}): super._();
  

 final  ConvertReport report;

/// Create a copy of Progress
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Progress_DoneCopyWith<Progress_Done> get copyWith => _$Progress_DoneCopyWithImpl<Progress_Done>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Progress_Done&&(identical(other.report, report) || other.report == report));
}


@override
int get hashCode => Object.hash(runtimeType,report);

@override
String toString() {
  return 'Progress.done(report: $report)';
}


}

/// @nodoc
abstract mixin class $Progress_DoneCopyWith<$Res> implements $ProgressCopyWith<$Res> {
  factory $Progress_DoneCopyWith(Progress_Done value, $Res Function(Progress_Done) _then) = _$Progress_DoneCopyWithImpl;
@useResult
$Res call({
 ConvertReport report
});




}
/// @nodoc
class _$Progress_DoneCopyWithImpl<$Res>
    implements $Progress_DoneCopyWith<$Res> {
  _$Progress_DoneCopyWithImpl(this._self, this._then);

  final Progress_Done _self;
  final $Res Function(Progress_Done) _then;

/// Create a copy of Progress
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? report = null,}) {
  return _then(Progress_Done(
report: null == report ? _self.report : report // ignore: cast_nullable_to_non_nullable
as ConvertReport,
  ));
}


}

// dart format on
