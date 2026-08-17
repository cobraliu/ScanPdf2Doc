// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'textlayer.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$OcrProgress {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is OcrProgress);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'OcrProgress()';
}


}

/// @nodoc
class $OcrProgressCopyWith<$Res>  {
$OcrProgressCopyWith(OcrProgress _, $Res Function(OcrProgress) __);
}


/// Adds pattern-matching-related methods to [OcrProgress].
extension OcrProgressPatterns on OcrProgress {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( OcrProgress_Loading value)?  loading,TResult Function( OcrProgress_Page value)?  page,TResult Function( OcrProgress_Done value)?  done,required TResult orElse(),}){
final _that = this;
switch (_that) {
case OcrProgress_Loading() when loading != null:
return loading(_that);case OcrProgress_Page() when page != null:
return page(_that);case OcrProgress_Done() when done != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( OcrProgress_Loading value)  loading,required TResult Function( OcrProgress_Page value)  page,required TResult Function( OcrProgress_Done value)  done,}){
final _that = this;
switch (_that) {
case OcrProgress_Loading():
return loading(_that);case OcrProgress_Page():
return page(_that);case OcrProgress_Done():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( OcrProgress_Loading value)?  loading,TResult? Function( OcrProgress_Page value)?  page,TResult? Function( OcrProgress_Done value)?  done,}){
final _that = this;
switch (_that) {
case OcrProgress_Loading() when loading != null:
return loading(_that);case OcrProgress_Page() when page != null:
return page(_that);case OcrProgress_Done() when done != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  loading,TResult Function( int index,  int total)?  page,TResult Function( List<PageText> pages)?  done,required TResult orElse(),}) {final _that = this;
switch (_that) {
case OcrProgress_Loading() when loading != null:
return loading();case OcrProgress_Page() when page != null:
return page(_that.index,_that.total);case OcrProgress_Done() when done != null:
return done(_that.pages);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  loading,required TResult Function( int index,  int total)  page,required TResult Function( List<PageText> pages)  done,}) {final _that = this;
switch (_that) {
case OcrProgress_Loading():
return loading();case OcrProgress_Page():
return page(_that.index,_that.total);case OcrProgress_Done():
return done(_that.pages);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  loading,TResult? Function( int index,  int total)?  page,TResult? Function( List<PageText> pages)?  done,}) {final _that = this;
switch (_that) {
case OcrProgress_Loading() when loading != null:
return loading();case OcrProgress_Page() when page != null:
return page(_that.index,_that.total);case OcrProgress_Done() when done != null:
return done(_that.pages);case _:
  return null;

}
}

}

/// @nodoc


class OcrProgress_Loading extends OcrProgress {
  const OcrProgress_Loading(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is OcrProgress_Loading);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'OcrProgress.loading()';
}


}




/// @nodoc


class OcrProgress_Page extends OcrProgress {
  const OcrProgress_Page({required this.index, required this.total}): super._();
  

 final  int index;
 final  int total;

/// Create a copy of OcrProgress
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$OcrProgress_PageCopyWith<OcrProgress_Page> get copyWith => _$OcrProgress_PageCopyWithImpl<OcrProgress_Page>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is OcrProgress_Page&&(identical(other.index, index) || other.index == index)&&(identical(other.total, total) || other.total == total));
}


@override
int get hashCode => Object.hash(runtimeType,index,total);

@override
String toString() {
  return 'OcrProgress.page(index: $index, total: $total)';
}


}

/// @nodoc
abstract mixin class $OcrProgress_PageCopyWith<$Res> implements $OcrProgressCopyWith<$Res> {
  factory $OcrProgress_PageCopyWith(OcrProgress_Page value, $Res Function(OcrProgress_Page) _then) = _$OcrProgress_PageCopyWithImpl;
@useResult
$Res call({
 int index, int total
});




}
/// @nodoc
class _$OcrProgress_PageCopyWithImpl<$Res>
    implements $OcrProgress_PageCopyWith<$Res> {
  _$OcrProgress_PageCopyWithImpl(this._self, this._then);

  final OcrProgress_Page _self;
  final $Res Function(OcrProgress_Page) _then;

/// Create a copy of OcrProgress
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? index = null,Object? total = null,}) {
  return _then(OcrProgress_Page(
index: null == index ? _self.index : index // ignore: cast_nullable_to_non_nullable
as int,total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class OcrProgress_Done extends OcrProgress {
  const OcrProgress_Done({required  List<PageText> pages}): _pages = pages,super._();
  

 final  List<PageText> _pages;
 List<PageText> get pages {
  if (_pages is EqualUnmodifiableListView) return _pages;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_pages);
}


/// Create a copy of OcrProgress
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$OcrProgress_DoneCopyWith<OcrProgress_Done> get copyWith => _$OcrProgress_DoneCopyWithImpl<OcrProgress_Done>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is OcrProgress_Done&&const DeepCollectionEquality().equals(other._pages, _pages));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_pages));

@override
String toString() {
  return 'OcrProgress.done(pages: $pages)';
}


}

/// @nodoc
abstract mixin class $OcrProgress_DoneCopyWith<$Res> implements $OcrProgressCopyWith<$Res> {
  factory $OcrProgress_DoneCopyWith(OcrProgress_Done value, $Res Function(OcrProgress_Done) _then) = _$OcrProgress_DoneCopyWithImpl;
@useResult
$Res call({
 List<PageText> pages
});




}
/// @nodoc
class _$OcrProgress_DoneCopyWithImpl<$Res>
    implements $OcrProgress_DoneCopyWith<$Res> {
  _$OcrProgress_DoneCopyWithImpl(this._self, this._then);

  final OcrProgress_Done _self;
  final $Res Function(OcrProgress_Done) _then;

/// Create a copy of OcrProgress
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? pages = null,}) {
  return _then(OcrProgress_Done(
pages: null == pages ? _self._pages : pages // ignore: cast_nullable_to_non_nullable
as List<PageText>,
  ));
}


}

// dart format on
