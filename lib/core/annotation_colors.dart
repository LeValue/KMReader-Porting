const annotationColors = {
  'Yellow': '#e6b72d',
  'Aqua': '#43bbc8',
  'Pink': '#e05c98',
  'Orange': '#f09546',
  'Green': '#3db98a',
};

const defaultAnnotationColor = '#e6b72d';

String? annotationColor(Object? value) {
  if (value is! String) return null;
  final color = value.trim().toLowerCase();
  if (RegExp(r'^#[0-9a-f]{6}$').hasMatch(color)) return color;
  return switch (color.split('.').last) {
    'yellow' => annotationColors['Yellow'],
    'aqua' || 'cyan' || 'blue' => annotationColors['Aqua'],
    'pink' || 'magenta' => annotationColors['Pink'],
    'orange' => annotationColors['Orange'],
    'green' => annotationColors['Green'],
    _ => null,
  };
}
